{-# LANGUAGE GADTs, NamedFieldPuns, OverloadedStrings, TupleSections, MultiWayIf #-}

{-| The worker is responsible for loading files, updating diagnostics, and
  dispatching requests.


  Files are updated using various update methods, and then explicitly
  re-compiled using 'refresh'. All complex work (either compiling, or
  dispatching threads), is done entirely asynchronously.

  The worker uses two threads: one compiles files, and another just
  dispatches requests. It might be possible to improve the concurrency of
  the worker in the future (such as multiple threads compiling), but
  currently the performance is good-enough.
-}
module AmuletLsp.Worker
  ( Version(..)
  , Worker
  , makeWorker
  , updateConfig

  -- * File updating
  , updateFile
  , touchFile
  , closeFile
  , findFile
  , refresh

  -- * Request handling
  , RequestKind(..)
  , Request(..)
  , startRequest, cancelRequest

  , forkIOWith
  ) where

import Control.Monad.Infer (TypeError(..))
import Control.Lens hiding (List)
import Control.Monad.Trans.Class
import Control.Concurrent.STM
import Control.Monad.IO.Class
import Control.Applicative
import Control.Monad.Namey
import Control.Concurrent
import Control.Monad
import GHC.Conc

import qualified Crypto.Hash.SHA256 as SHA

import qualified Data.Text.Lazy.Encoding as L
import qualified Data.ByteString.Lazy as BSL
import qualified Data.HashMap.Strict as HM
import qualified Data.List.NonEmpty as E
import qualified Data.Rope.UTF16 as Rope
import qualified Data.Map.Strict as Map
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Data.Bifunctor
import Data.Foldable
import Data.Function
import Data.Functor
import Data.Either
import Data.Monoid
import Data.Triple
import Data.These
import Data.Span

import Frontend.Errors
import Frontend.Files

import Language.LSP.Types hiding (SemanticTokenRelative(length), SemanticTokenAbsolute(length))

import Parser.Wrapper (runParser)
import Parser.Error (ParseError)
import Parser (parseTops)

import Syntax.Resolve (ResolveResult(..), resolveProgram)
import Syntax.Builtin (builtinResolve, builtinEnv)
import Syntax.Resolve.Scope (Signature)
import Syntax.Desugar (desugarProgram)
import qualified Syntax.Resolve as R
import Syntax (Toplevel(..))
import Syntax.Resolve.Import
import System.Log.Logger
import System.Directory hiding (findFile)
import System.FilePath
import Syntax.Verify
import Syntax.Types
import Syntax.Var

import CompileTarget (Target)

import Text.Pretty.Note

import Types.Infer (inferProgram)

import AmuletLsp.NameyMT

-- | A unique version used to identify currently edited files.
newtype Version = Version Int
  deriving (Show, Eq)

-- | A piece of data, which was last loaded at a specific version.
data VersionedData a
  = NotLoaded
  | VersionedData
    { -- | The last version at which this succeeded. This is used to map source
      -- locations, and so uses versions rather than clock ticks.
      lastSuccess :: {-# UNPACK #-} !Version

      -- | The result of this loaded data.
    , value :: !a
    }
  deriving Show

-- | Counter to represent the current version of the whole world.
newtype Clock = Clock Int
  deriving (Show, Eq, Ord)

-- | Increment the clock by one.
tick :: Clock -> Clock
tick (Clock x) = Clock (x + 1)

-- | Information about the contents of a file.
data FileContents
  -- | A file which has been opened within the editor.
  = OpenedContents
    { -- | The file's contents, and the version it was last updated at.
      openVersion  :: {-# UNPACK #-} !Version
    , openContents :: Rope.Rope
    }
  -- | A file which exists on disk.
  | DiskContents
    { diskDirty    :: !Bool -- ^ Set when the file needs to be reloaded from disk.
    }
  deriving Show

data Working
  -- | This file has been loaded. Clock is the /current/ clock. This does
  -- not indicate that the file did not error, simply that we finished
  -- processing it.
  = Done Clock
  -- | A file which is currently being worked upon. This is a root file,
  -- and thus wasn't imported by anyone else.
  | WorkingRoot
  -- | Like 'WorkingRoot', but imported by another file at a specific
  -- location.
  | WorkingDep NormalizedUri Span
  deriving Show

data FileState
  -- | A file which has been opened within the editor.
  --
  -- We keep track of the last time we successfully managed to produce
  -- meaningful output at each stage - this is used to provide analysis when the
  -- file doesn't currently compile.
  = OpenedState
    { fileVar      :: Name

      -- | Whether this file is "done" (entirely up-to-date), or still being
      -- worked on.
      --
      -- Note, if "done", this contains the /current/ clock, rather than the one
      -- at which it was last compiled.
    , working      :: Working

      -- | The time this file was last compiled. This must be greater or equal
      -- to any of its dependencies.
    , compileClock :: Clock
      -- | The time this file was last checked for changes. This is used as a
      -- mechanism to prevent checking every time.
    , checkClock   :: Clock

    , dependencies :: HM.HashMap NormalizedUri Span

    , openPVersion :: Maybe Version -- ^ The last version which we tried to /parse/.
    , openParsed   :: VersionedData [Toplevel Parsed]
    , openResolved :: VersionedData (Signature, [Toplevel Resolved])
    , openTyped    :: VersionedData (Signature, Env, [Toplevel Typed])

    , errors       :: !ErrorBundle
    }
  -- | A file which is currently saved on disk.
  | DiskState
    { fileVar      :: Name
    , working      :: Working
    , compileClock :: Clock
    , checkClock   :: Clock
    , dependencies :: HM.HashMap NormalizedUri Span

    , diskPHash    :: Maybe BS.ByteString -- ^ The last hash which we tried to /parse/.
    , diskParsed   :: Maybe [Toplevel Parsed]
    , diskResolved :: Maybe Signature
    , diskTyped    :: Maybe Env
    }
  deriving Show

data RequestKind a where
  ReqParsed   :: RequestKind (Maybe [Toplevel Parsed])
  ReqResolved :: RequestKind (Maybe (Signature, [Toplevel Resolved]))
  ReqTyped    :: RequestKind (Maybe (Signature, [Toplevel Resolved], Env, [Toplevel Typed]))
  ReqErrors   :: RequestKind ErrorBundle

data Request where
  -- | Use the result of the current file when processing has finished.
  RequestLatest
    :: NormalizedUri
    -> RequestKind a
    -- ^ The kind of the request. This determines what data is fetched from the
    -- store.
    -> (ResponseError -> IO ())
    -- ^ A function to call on error (such as being cancelled, or file is not
    -- open). This should just send the response immediately.
    -> (Name -> Version -> a -> IO ())
    -- ^ A function to call on success. Is called with the file's ID, the
    -- current version and appropriate data.
    -> Request

requestFile :: Request -> NormalizedUri
requestFile (RequestLatest file _ _ _) = file

data Worker = Worker
  { -- | Report errors back to the client.
    pushErrors   :: NormalizedUri -> ErrorBundle -> IO ()

  , refreshThread :: ThreadId -- ^ The thread the main worker runs on.
  , requestThread :: ThreadId -- ^ The task requests are run on.

    -- | The complete path to resolve libraries on.
  , libraryPath  :: TVar [FilePath]

    -- | The compile target, use for resolution.
  , target       :: Target

    -- | A mapping of file names to some representation of their contents. This
    -- is updated immediately whenever a file changes.
  , fileContents :: TVar (HM.HashMap NormalizedUri FileContents)

    -- | The actual internal states of each file. These are updated in one go,
    -- in order to ensure they are all in a consistent state.
  , fileStates   :: TVar (HM.HashMap NormalizedUri FileState)

    -- | A map of each 'FileState''s 'fileVar', to its URI. As names can be more
    -- compactly encoded (i.e just a name), we prefer them when communicating
    -- with the client.
  , fileVars     :: TVar (Map.Map Name NormalizedUri)

     -- | The current global version that "fileContents" is on.
  , clock        :: TVar Clock

    -- | The next name to use for fresh name generation.
  , nextName     :: TVar Int

    -- | Updated when a refresh should occur. When present, a refresh should
    -- occur. When the contents is 'Just', this will be the file which should
    -- be prioritised.
  , toRefresh    :: TVar (Maybe (Maybe NormalizedUri))

    -- | A lookup of unsatisfied request ids to their corresponding
    -- requests, and also a map of uris to their pending requests.
  , pendingRequests :: TVar ( Map.Map SomeLspId Request
                            , HM.HashMap NormalizedUri (Map.Map SomeLspId Request) )
    -- | Requests which are satisfied and ready to be executed.
  , readyRequests   :: TVar (Map.Map SomeLspId Request)
  }

-- | Construct a worker from a library path, and some "error reporting" function.
makeWorker :: [FilePath] -> Target -> (NormalizedUri -> ErrorBundle -> IO ()) -> IO Worker
makeWorker extra target pushErrors = do
  path <- (extra++) <$> buildLibraryPath
  current <- myThreadId
  worker <- atomically $ Worker pushErrors current current
    <$> newTVar path      -- Library path
    <*> pure    target    -- Compile target
    <*> newTVar mempty    -- File contents
    <*> newTVar mempty    -- File states
    <*> newTVar mempty    -- File vars
    <*> newTVar (Clock 0) -- Clock
    <*> newTVar 0         -- Next name
    <*> newTVar Nothing   -- To refresh
    <*> newTVar mempty    -- Pending requests
    <*> newTVar mempty    -- Ready requests
  refId <- forkIOWith "Refresh" (runRefresh worker)
  reqId <- forkIOWith "Requests" (runRequests worker)
  pure worker { refreshThread = refId, requestThread = reqId }

updateConfig :: Worker -> [FilePath] -> IO ()
updateConfig wrk extra = do
  path <- (extra++) <$> buildLibraryPath
  atomically $ writeTVar (libraryPath wrk) path

-- | Update the contents of a file.
updateFile :: Worker -> NormalizedUri -> Version -> Rope.Rope -> IO ()
updateFile wrk path version contents = atomically $ do
  modifyTVar (fileContents wrk) (HM.insert path (OpenedContents version contents))
  modifyTVar (clock wrk) tick

-- | Mark an unopened file as having changed.
--
-- As we try to avoid hitting the disk as much as possible, we entirely rely on
-- a separate tool to watch files and order recompilation.
touchFile :: Worker -> NormalizedUri -> IO ()
touchFile wrk path = atomically $ do
  modifyTVar (fileContents wrk) (HM.update update path)
  modifyTVar (clock wrk) tick

  where
    update f@DiskContents{} = Just f { diskDirty = True }
    update f = Just f

-- | Close a open file.
closeFile :: Worker -> NormalizedUri -> IO ()
closeFile wrk path = atomically $ do
  -- TODO: Optimise this, we should be able to demote if on-disk matches our
  -- contents.
  modifyTVar (fileContents wrk) (HM.delete path)
  modifyTVar (clock wrk) tick

-- | Try to locate a file from its name.
findFile :: Worker -> Name -> IO (Maybe NormalizedUri)
findFile wrk name = Map.lookup name <$> readTVarIO (fileVars wrk)

-- | Reload any out-of-date files, recompiling them and their dependents.
refresh :: Worker -> Maybe NormalizedUri -> IO ()
refresh wrk file = atomically $ do
  -- Update the current "toRefresh" variable. This will always choose the latest
  -- "priority" file.
  current <- readTVar (toRefresh wrk)
  case current of
    Just{} | Nothing <- file -> pure ()
    _ -> writeTVar (toRefresh wrk) (Just file)

trySatisfyRequest :: Worker -> Request -> STM (Maybe (IO ()))
trySatisfyRequest wrk (RequestLatest file kind err ok) = do
  clk <- readTVar (clock wrk)
  files <- readTVar (fileStates wrk)
  contents <- readTVar (fileContents wrk)
  pure $ case (HM.lookup file files, HM.lookup file contents) of
    -- The file isn't opened, so we'll just error.
    (_, Nothing) ->
      Just $ err (ResponseError InvalidRequest "File is not open" Nothing)
    (_, Just DiskContents{}) ->
      Just $ err (ResponseError InvalidRequest "File is not open" Nothing)

    (  Just OpenedState{ fileVar, openPVersion, openParsed, openResolved, openTyped, working, errors }
     , Just OpenedContents { openVersion } ) ->
      let ok' = ok fileVar openVersion
      in case kind of
        ReqParsed
          | VersionedData v contents <- openParsed, v == openVersion -> Just $ ok' (Just contents)
          | Just v <- openPVersion, v == openVersion -> Just $ ok' Nothing
          | otherwise -> Nothing

        ReqResolved
          | Done c <- working, c == clk ->
            case openResolved of
              VersionedData v contents | v == openVersion -> Just $ ok' (Just contents)
              _ -> Just $ ok' Nothing
          | otherwise -> Nothing

        ReqTyped
          | Done c <- working, c == clk ->
            case openTyped of
              VersionedData v (sig, env, tProg)
                | v == openVersion
                -- This is guaranteed to be the same version, as we're on the
                -- latest version/clock.
                , VersionedData _ (_, rProg) <- openResolved
                -> Just $ ok' (Just (sig, rProg, env, tProg))
              _ -> Just $ ok' Nothing
          | otherwise -> Nothing

        ReqErrors
          | Done c <- working, c == clk -> Just $ ok' errors
          | otherwise -> Nothing

    (_, Just OpenedContents{}) -> Nothing

-- | Add a new request, which will be run when the state is ready.
startRequest :: Worker -> SomeLspId -> Request -> IO ()
startRequest wrk lId req = do
  debugM logN ("Queuing request " ++ show lId)
  atomically $ do
    sat <- trySatisfyRequest wrk req
    case sat of
      Just{} -> modifyTVar (readyRequests wrk) (Map.insert lId req)
      Nothing ->
        modifyTVar (pendingRequests wrk) $ bimap
          (Map.insert lId req)
          (HM.alter (Just . Map.insert lId req . fold) (requestFile req))

-- | Cancel a pending or ready request. This will not interrupt already
-- running requests.
cancelRequest :: Worker -> SomeLspId -> IO ()
cancelRequest wrk id = atomically $ do
  modifyTVar (readyRequests wrk) (Map.delete id)
  modifyTVar (pendingRequests wrk) $ \(reqs, fileReqs) ->
    let (req, reqs') = Map.updateLookupWithKey (\_ _ -> Nothing) id reqs
    in case req of
      Nothing -> (reqs, fileReqs)
      Just req -> (reqs', HM.adjust (Map.delete id) (requestFile req) fileReqs)

-- | Queue any pending for a file which are now ready to be executed.
queueRequests :: Worker -> NormalizedUri -> IO ()
queueRequests wrk@Worker { readyRequests, pendingRequests } path = atomically $ do
  (idReqs, fileReqs) <- readTVar pendingRequests
  case HM.lookup path fileReqs of
    Nothing -> pure ()
    Just filePending -> do
      sats <- Map.foldrWithKey (\lId req sats -> maybe id (const (Map.insert lId req)) <$> trySatisfyRequest wrk req <*> sats)
               (pure mempty) filePending
      if Map.null sats then pure () else do
        modifyTVar readyRequests (Map.union sats)
        writeTVar pendingRequests (idReqs Map.\\ sats, HM.insert path (filePending Map.\\ sats) fileReqs)

-- | A background thread to run requests.
runRequests :: Worker -> IO ()
runRequests wrk@Worker { readyRequests, pendingRequests } = forever (join findAction) where
  findAction :: IO (IO ())
  findAction = maybe findAction pure <=< atomically $ do
    -- Pull a request from the ready queue and attempt to satisfy
    -- it. Remove it from the queue, and either run it or add it back
    -- to the pending queue.
    requests <- readTVar readyRequests
    case Map.minViewWithKey requests of
      Nothing -> retry
      Just ((lId, req), requests) -> do
        action <- trySatisfyRequest wrk req
        writeTVar readyRequests requests
        case action of
          Just{} -> pure ()
          Nothing ->
            modifyTVar pendingRequests $ bimap
              (Map.insert lId req)
              (HM.alter (Just . Map.insert lId req . fold) (requestFile req))
        pure ((*> debugM logN ("Run request " ++ show lId)) <$> action)

-- | Generate a singular name with the given text.
genOneName :: Worker -> T.Text -> STM Name
genOneName wrk txt = do
  n <- readTVar (nextName wrk)
  writeTVar (nextName wrk) (n + 1)
  pure (TgName txt n)

-- | Watch the 'toRefresh' variable and issue a rebuild whenever it
-- changes.
runRefresh :: Worker -> IO ()
runRefresh wrk@Worker { toRefresh, clock } = work Nothing where
  work :: Maybe ThreadId -> IO ()
  work task = do
    debugM logN "Polling state"
    (refresh, clk) <- atomically $ do
      -- Treat toRefresh as a TMVar - if not present, then retry. Otherwise
      -- clear immediately.
      refresh <- readTVar toRefresh
      refresh <- case refresh of
        Nothing -> retry
        Just x -> writeTVar toRefresh Nothing $> x
      clk <- readTVar clock
      pure (refresh, clk)

    -- If we've got an existing worker, kill it. This may throw some work away,
    -- but as 'workOnce' incrementally commits files, it's not the end of the
    -- world.
    case task of
      Nothing -> pure ()
      Just tid -> do
        infoM logN "Killing previous task"
        killThread tid

    -- Spin up the worker on a separate thread and wait for further changes.
    infoM logN ("Recompiling " ++ maybe "everything" showUri refresh)
    task <- forkIOWith ("Recompiling " ++ maybe "everything" showUri refresh) (workOnce wrk clk refresh)
    work (Just task)

-- | A file importer which loads a file using an arbitrary function,
-- keeping track of dependencies.
newtype FileImport m a = FileIm
  { runFileImport :: (Worker, NormalizedUri, NormalizedUri -> Maybe (NormalizedUri, Span) -> IO (Maybe FileState))
                  -> m (a, HM.HashMap NormalizedUri (Span, Maybe Env)) }

instance Functor f => Functor (FileImport f) where
  fmap f (FileIm go) = FileIm $ fmap (first f) . go

instance Applicative f => Applicative (FileImport f) where
  pure x = FileIm (\_ -> pure (x, mempty))
  (FileIm f) <*> (FileIm x) = FileIm $ \c -> liftA2 k (f c) (x c)
    where k (f, w) (x, w') = (f x, w <> w')

instance Monad m => Monad (FileImport m) where
  x >>= f = FileIm $ \c -> do
    (x, w) <- runFileImport x c
    (y, w') <- runFileImport (f x) c
    pure (y, w <> w')

instance MonadTrans FileImport where
  lift m = FileIm $ \_ -> (,mempty) <$> m

instance MonadNamey m => MonadNamey (FileImport m) where
  genName = lift genName

instance MonadIO m => MonadImport (FileImport m) where
  importModule loc relPath = FileIm $ \(wrk, curFile, load) -> liftIO $ do
    absFile <-
      if T.pack "." `T.isPrefixOf` relPath
      then case uriToFilePath (fromNormalizedUri curFile) of
             Nothing -> pure (Left (Relative (T.unpack relPath)))
             Just curFile -> Right <$> canonicalizePath (dropFileName curFile </> T.unpack relPath)
      else do
        libPath <- readTVarIO (libraryPath wrk)
        first LibraryPath <$> findFile' (map (</> T.unpack relPath) libPath)

    case absFile of
      Left err -> pure (NotFound err, mempty)
      Right absFile -> do
        file <- load (toNorm absFile) (Just (curFile, loc))
        case file of
          Nothing -> ret absFile Nothing (NotFound (Relative absFile))

          -- File is up-to-date
          Just DiskState { working = Done _, diskResolved = Nothing } ->
            ret absFile Nothing Errored
          Just DiskState { fileVar, working = Done _, diskResolved = Just resolved, diskTyped } ->
            ret absFile diskTyped (Imported fileVar resolved)
          Just OpenedState { fileVar, working = Done _, openPVersion, openResolved, openTyped }
             | VersionedData v (sig, _) <- openResolved, Just pv <- openPVersion, v == pv ->
               let env = case openTyped of
                     VersionedData v (_, env, _) | v == pv -> Just env
                     _ -> Nothing
               in ret absFile env (Imported fileVar sig)
             | otherwise -> ret absFile Nothing Errored

          -- File is still being loaded: try to identify the cycle.
          Just file ->
            case working file of
              WorkingRoot -> do
                debugM logN ("Cycle importing " ++ absFile ++ " / " ++ show (working file))
                ret absFile (Just mempty) . ImportCycle $
                  (T.pack (getRel curFile (toNorm absFile)), fixLoc curFile loc) E.:| []
              WorkingDep _ loc -> do
                warningM logN ("Cycle importing " ++ absFile)
                -- TODO: Enumerate the whole graph
                ret absFile (Just mempty) . ImportCycle $
                  (T.pack (getRel curFile (toNorm absFile)), fixLoc curFile loc) E.:| []
              Done _ -> error "Impossible"

    where
      toNorm = toNormalizedUri . filePathToUri

      fixLoc _ span = span -- TODO: Fix positions

      ret path state res = pure (res, HM.singleton (toNorm path) (loc, state))

-- | Reprocess any changed files, reloading/recompiling them and their dependencies.
--
-- This should never be called directly, as it is not safe to run
-- multiple instances of 'workOnce' at once. Instead, 'runRefresh' will
-- make sure a single 'workOnce' instance is dispatched at-a-time.
workOnce :: Worker -- ^ The worker to evaluate in
         -> Clock
         -> Maybe NormalizedUri
         -> IO ()
workOnce wrk@Worker { pushErrors, fileContents, fileStates, fileVars, target } baseClock priority = do
  case priority of
    Nothing -> pure ()
    Just path -> loadFile path Nothing $> ()

  rest <- atomically $ HM.foldrWithKey justOpens [] <$> readTVar fileContents
  for_ rest (\f -> loadFile f Nothing $> ())

  where

  -- | Load a single file, specifying which file required this one.
  --
  -- Called from MonadImport (and itself).
  --
  -- This returns the file's state, or Nothing if the file does not exist.
  loadFile :: NormalizedUri -> Maybe (NormalizedUri, Span) -> IO (Maybe FileState)
  loadFile path from = do
    debugM logN ("Importing " ++ showUri path ++ " from " ++ maybe "?" (showUri . fst) from)
    oldFile <- atomically (HM.lookup path <$> readTVar fileStates)
    case oldFile of
      -- We've already checked this tick, don't do anything.
      Just file | checkClock file == baseClock -> pure (Just file)

      _ -> do
        (changed, parsed, file) <- parseFile path oldFile
        -- Update the file, at least a little
        case file of
          Nothing -> do
            -- We couldn't find the file at all - delete it from our cache.
            atomically $ do
              modifyTVar fileStates (HM.delete path)
              maybe (pure ()) (modifyTVar fileVars . Map.delete . fileVar) oldFile

            queueRequests wrk path
            pure Nothing
          Just file -> do
            -- Otherwise check each dependency. We update the clock and working
            -- state beforehand, to avoid getting into any dependency loops.
            atomically $ do
              -- Update var mapping
              case oldFile of
                Just oldFile
                  | fileVar oldFile /= fileVar file
                  -> modifyTVar fileVars ( Map.delete (fileVar oldFile)
                                         . Map.insert (fileVar file) path )
                  | otherwise -> pure ()
                Nothing -> modifyTVar fileVars (Map.insert (fileVar file) path)

              modifyTVar fileStates . HM.insert path $
                file { checkClock = baseClock
                     , working = maybe WorkingRoot (uncurry WorkingDep) from }

            Any changed <- if
              -- Short circuit if this file ever changed
              | changed -> pure (Any True)
              -- If this file never completed last time, just mark it as changed.
              | inProgress (working file) && checkClock file /= baseClock
              -> infoM logN (showUri path ++ " never completed, retrying") $> Any True
              -- If this file has been loaded before its dependency, then the dependency
              -- was loaded on a later clock tick, and so we're out of date.
              | otherwise ->
                  foldMapM (\(dPath, loc) -> Any . maybe True (on (<) compileClock file) <$> loadFile dPath (Just (path, loc)))
                           (HM.toList (dependencies file))

            debugM logN $ "Starting " ++ showUri path
              ++ ". State: "   ++ (case file of OpenedState{} -> "opened" ; DiskState{} -> "on disk")
              ++ ", Changed: " ++ show changed

            file <- if not changed then pure file else
              case parsed of
                Nothing -> infoM logN (showUri path ++ ": parsing returned nil") >> pure file
                Just parsed -> do
                  debugM logN ("Resolving " ++ showUri path)
                  (errors, resolved, typed) <-
                    loadFrom path parsed
                      (case file of { OpenedState{} -> True; DiskState{} -> False })
                  pure $ case file of
                    f@DiskState{} ->
                      f { diskResolved = fst <$> resolved
                        , diskTyped    = snd3 <$> typed }
                    f@OpenedState{ openPVersion } ->
                      let (Just v) = openPVersion in
                      f { openResolved = maybe (openResolved f) (VersionedData v) resolved
                        , openTyped    = maybe (openTyped f) (VersionedData v) typed
                        , errors }

            -- Mark us as done and update the file.
            let file' = file { working = Done baseClock }
            debugM logN ("Finished " ++ showUri path)
            updateFile path file'
            case file' of
              OpenedState{ errors } -> when changed (pushErrors path errors)
              DiskState{} -> pure ()
            queueRequests wrk path
            pure (Just file')

  -- | Parse a file, updating the state and returning whether it changed or not.
  parseFile :: NormalizedUri -> Maybe FileState -> IO (Bool, Maybe [Toplevel Parsed], Maybe FileState)
  parseFile path@(NormalizedUri _ tPath) state = do
    contents <- atomically (HM.lookup path <$> readTVar fileContents)
    case contents of
      -- If we've no file contents at all, attempt to read from disk. If the
      -- file exists, we write the hash back to the contents store (if no
      -- changes have occurred) and save.
      Nothing -> do
        contents <- readDisk path
        case contents of
          Nothing -> pure (False, Nothing, Nothing)
          Just (sha, contents) -> do
            -- Add the file to the contents store.
            atomically $ do
              allContents <- readTVar fileContents
              case HM.lookup path allContents of
                Just{} -> pure ()
                Nothing -> writeTVar fileContents (HM.insert path (DiskContents False) allContents)

            case state of
              -- If we've magically got a disk state, and the file didn't
              -- change, then preserve it.
              Just f@DiskState { diskPHash = Just hash, diskParsed }
                | hash == sha -> pure (False, diskParsed, Just f)
              _ ->
                let (parsed, _) = runParser tPath (L.decodeUtf8 contents) parseTops
                in (True,parsed,) . Just <$> parseOfDisk path parsed sha state

      Just DiskContents { diskDirty }
        | not diskDirty, Just f@DiskState{ diskParsed } <- state ->
          pure (False, diskParsed, Just f)
        | otherwise -> do
            -- TODO: Clear the dirty flag!
            contents <- readDisk path
            case contents of
              Nothing -> pure (True, Nothing, Nothing)
              Just (sha, contents) ->
                let (parsed, _) = runParser tPath (L.decodeUtf8 contents) parseTops
                in (True,parsed,) . Just <$> parseOfDisk path parsed sha state

      Just OpenedContents { openVersion, openContents }
        | Just f@OpenedState { openPVersion = Just v, openParsed } <- state
        , v == openVersion ->
          let parsed = case openParsed of
                VersionedData v x | v == openVersion -> Just x
                _ -> Nothing
          in pure (False, parsed, Just f)

        | otherwise -> do
            let (parsed, es) = runParser tPath (Rope.toLazyText openContents) parseTops
            state' <- case state of
              Just f@OpenedState { openParsed } -> pure $ f
                { checkClock = baseClock
                , compileClock = baseClock
                , working = WorkingRoot
                , dependencies = mempty

                , openPVersion = Just openVersion
                , openParsed = maybe openParsed (VersionedData openVersion) parsed
                , errors = mempty & parseErrors .~ es }

              Just DiskState { fileVar } -> pure (freshOpen fileVar openVersion parsed es)
              Nothing -> do
                name <- atomically $ nameOf path
                pure (freshOpen name openVersion parsed es)

            pure (True, parsed, Just state')

  -- | Parse a file from the contents on disk, transforming a state to a "disk state".
  parseOfDisk :: NormalizedUri -> Maybe [Toplevel Parsed] -> BS.ByteString -> Maybe FileState -> IO FileState
  parseOfDisk _ parsed hash (Just f@DiskState{}) =
    -- If we've got an old disk state, update it.
    pure f
      { working = WorkingRoot
      , checkClock = baseClock
      , compileClock = baseClock
      , dependencies = mempty

      , diskPHash = Just hash
      , diskParsed = parsed }
  parseOfDisk _ parsed hash (Just OpenedState{ fileVar }) = pure (freshDisk fileVar hash parsed)
  parseOfDisk path parsed hash Nothing = do
    name <- atomically $ nameOf path
    pure (freshDisk name hash parsed)

  -- | Run the actual loading pass. This resolves the file (including any
  -- imports), then desugars, types and optionally verifies it.
  loadFrom :: NormalizedUri -> [Toplevel Parsed] -> Bool
           -> IO (ErrorBundle, Maybe (Signature, [Toplevel Resolved]), Maybe (Signature, Env, [Toplevel Typed]))
  loadFrom path parsed verify = flip evalNameyMT (nextName wrk) $ do
    (resolved, dependencies) <- flip runFileImport (wrk, path, loadFile) $ resolveProgram target builtinResolve parsed
    let env = HM.foldrWithKey (getEnvs path) (Right builtinEnv) dependencies
    case (resolved, env) of
      (Right (ResolveResult resolved sig _), Right env) -> do
        typed <- desugarProgram resolved >>= inferProgram env
        let (tyRes, tEs) = case typed of
              (That x) -> (Just x, mempty)
              (This es) -> (Nothing, es)
              (These es x) | any isTyError es -> (Nothing, es)
                           | otherwise -> (Just x, es)
        vEs <- case tyRes of
          Just (prog, env) | verify -> do
            name <- genName
            pure . toList . snd . runVerify env target name $ verifyProgram prog
          _ -> pure []

        pure ( mempty & (typeErrors .~ tEs) . (verifyErrors .~ vEs)
             , Just (sig, resolved)
             , (\(prog, modEnv) -> (sig, env <> modEnv, prog)) <$> tyRes )

      (Right (ResolveResult resolved sig _), Left es) ->
        pure ( mempty & resolveErrors .~ es
             , Just (sig, resolved)
             , Nothing )

      (Left es, _) ->
        pure ( mempty & resolveErrors .~ (fromLeft [] env ++ es)
             , Nothing, Nothing )

  getEnvs :: NormalizedUri -> NormalizedUri -> (Span, Maybe Env) -> Either [R.ResolveError] Env
          -> Either [R.ResolveError] Env
  getEnvs curPath file (loc, Nothing) es = Left
    $ R.ImportError loc (getRel curPath file)
    : fromLeft [] es
  getEnvs _ _ (_, Just _) es@Left{} = es
  getEnvs _ _ (_, Just env) (Right env') = Right (env <> env')

  isTyError (ArisingFrom e _) = isTyError e
  isTyError FoundHole{} = False
  isTyError x = diagnosticKind x == ErrorMessage

  freshDisk :: Name -> BS.ByteString -> Maybe [Toplevel Parsed] -> FileState
  freshDisk name hash parsed =
    DiskState
    { fileVar = name
    , checkClock = baseClock
    , compileClock = baseClock
    , working = WorkingRoot
    , dependencies = mempty

    , diskPHash = Just hash
    , diskParsed = parsed
    , diskResolved = Nothing
    , diskTyped = Nothing }

  freshOpen :: Name -> Version -> Maybe [Toplevel Parsed] -> [ParseError] -> FileState
  freshOpen name version parsed es =
    OpenedState
    { fileVar = name
    , working = WorkingRoot
    , checkClock = baseClock
    , compileClock = baseClock
    , dependencies = mempty

    , openPVersion = Just version
    , openParsed = maybe NotLoaded (VersionedData version) parsed
    , openResolved = NotLoaded
    , openTyped = NotLoaded
    , errors = mempty & parseErrors .~ es }


  -- | Read a file from disk.
  readDisk :: NormalizedUri -> IO (Maybe (BS.ByteString, BSL.ByteString))
  readDisk path =
    case uriToFilePath (fromNormalizedUri path) of
      Nothing -> pure Nothing
      Just path -> do
        exists <- doesFileExist path
        if not exists then pure Nothing else do
          contents <- BSL.readFile path
          pure (Just (SHA.hashlazy contents, contents))


  nameOf :: NormalizedUri -> STM Name
  nameOf (NormalizedUri _ name) = genOneName wrk ("\"" <> name <> "\"")

  updateFile :: NormalizedUri -> FileState -> IO ()
  updateFile path = atomically . modifyTVar fileStates . HM.insert path

  justOpens f OpenedContents{} xs = f : xs
  justOpens _ DiskContents{} xs = xs


-- | Make one file relative to another's directory.
getRel :: NormalizedUri -> NormalizedUri -> FilePath
getRel curFile path =
  case (uriToFilePath (fromNormalizedUri curFile), uriToFilePath (fromNormalizedUri path)) of
    (Just f, Just p)
      | rel <- makeRelative (dropFileName f) p
      , length rel <= length p -> rel
    (_ , Just p) -> p
    (_, Nothing) | NormalizedUri _ path <- path -> T.unpack path

logN :: String
logN = "AmuletLsp.Worker"

forkIOWith :: String -> IO () -> IO ThreadId
forkIOWith label action = do
  t <- forkIO action
  labelThread t label
  infoM logN $ "Thread " ++ show t ++ " has name " ++ label
  pure t

inProgress :: Working -> Bool
inProgress Done{} = False
inProgress WorkingRoot{} = True
inProgress WorkingDep{} = True

showUri :: NormalizedUri -> String
showUri (NormalizedUri _ u) = T.unpack u
