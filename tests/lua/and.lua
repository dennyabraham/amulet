do
  local __builtin_unit = {
    __tag = "__builtin_unit"
  }
  local function __builtin_force (x)
    if x[2] then
      return x[1]
    else
      x[1], x[2] = x[1](__builtin_unit), true
      return x[1]
    end
  end
  local function __builtin_Lazy (x)
    return {
      [1] = x,
      [2] = false,
      __tag = "lazy"
    }
  end
  local bottom = nil
  if bottom(1) then
    bottom(__builtin_force(__builtin_Lazy(function (cq)
      return bottom(2)
    end)))
  else
    bottom(false)
  end
end
