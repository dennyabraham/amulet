external val random : int -> int -> int = "math.random" ;
external val random_seed : int -> unit  = "math.randomseed" ;

external val print_endline : string -> unit = "print" ;
external val print : string -> unit  = "io.write" ;
external val read : string -> string  = "io.read" ;

external val current_time : unit -> int  = "os.time" ;

external val prim_int_of_string : string -> int  = "tonumber" ;
external val string_of_int : int -> string  = "tostring" ;

external val transmute : 'a -> 'b  = "(function(a) return a end)" ;

type option 'a =
  | Just 'a
  | Nothing
  ;

let int_of_string str
  = let vl = prim_int_of_string str
    in if transmute vl == unit then
      Nothing
    else
      Just vl
;

let read_line _ = read "*l"
and main _ =
  begin
    random_seed (current_time unit) ;
    let vl = random 1 10
    and loop _ = begin
      print "Guess a number between 1 and 10: " ;
      let read = int_of_string (read_line unit)
       in match read with
          | Just guess ->
              if vl == guess then
                print_endline "You got it right!"
              else if vl > guess then begin
                   print_endline "Too low!"; loop unit
              end else if vl < guess then begin
                   print_endline "Too high!"; loop unit
              end else loop unit
          | Nothing -> print_endline "Bye"
    end in loop unit
  end