-- Directional focus navigation for mouse-driven UI.
-- A direction press moves the mouse onto the nearest interactive object that way, so hover and
-- click handling stay the objects' own. Candidates are the interact_with_mouse objects of groups
-- updated on the previous tick, which leaves out groups a scene freezes behind a modal.
navigation = {}

local groups = setmetatable({}, {__mode = 'k'})
local directions = {up = {0, -1}, down = {0, 1}, left = {-1, 0}, right = {1, 0}}
local repeat_delay, repeat_interval = 0.35, 0.12
-- Weight of sideways offset against distance along the direction when ranking candidates.
local perpendicular_weight = 2
-- Samples per axis when searching a container for a point clear of the objects nested in it.
local aim_samples = 7
local hold_timers = {}
local last_x, last_y

-- True while the mouse sits where navigation put it; false once a real mouse moves it.
navigation.active = false


-- Tracks a group as a source of navigation candidates.
function navigation.register(group)
  groups[group] = true
end


-- Binds the direction actions navigation reads.
function navigation.bind()
  input:bind('navigate_up', {'up', 'dpup', 'lsup'})
  input:bind('navigate_down', {'down', 'dpdown', 'lsdown'})
  input:bind('navigate_left', {'left', 'dpleft', 'lsleft'})
  input:bind('navigate_right', {'right', 'dpright', 'lsright'})
end


-- Returns the screen-space position of a group-space point, in game units.
local function screen_position(group, x, y)
  if group.camera then return group.camera:get_local_coords(x, y) end
  return x, y
end


-- Returns the area of a shape's bounds, or 0 for a shape without them.
local function area(shape)
  return (shape.w or 0)*(shape.h or 0)
end


-- Returns the point of the container closest to its centre that no nested object covers.
local function aim_point(container, nested)
  local shape = container.object.shape
  local best_x, best_y, best_d = container.object.x, container.object.y
  for i = 0, aim_samples - 1 do
    for j = 0, aim_samples - 1 do
      local x = shape.x - shape.w/2 + shape.w*(i + 0.5)/aim_samples
      local y = shape.y - shape.h/2 + shape.h*(j + 0.5)/aim_samples
      local covered = false
      for _, n in ipairs(nested) do
        if n.object.shape:is_colliding_with_point(x, y) then covered = true; break end
      end
      local d = (x - container.object.x)^2 + (y - container.object.y)^2
      if not covered and (not best_d or d < best_d) then best_x, best_y, best_d = x, y, d end
    end
  end
  return best_x, best_y
end


-- Returns every focusable object with its screen aim point, from the given groups or else from the
-- groups updated on the previous tick. Objects nested inside another one are left out.
local function get_candidates(scene_groups)
  local all = {}
  local function collect(group)
    for _, object in ipairs(group.objects) do
      if object.interact_with_mouse and object.shape and not object.dead and not object.hidden then
        table.insert(all, {object = object, group = group})
      end
    end
  end
  if scene_groups then
    for _, group in ipairs(scene_groups) do collect(group) end
  else
    for group in pairs(groups) do
      if group.update_frame == frame - 1 then collect(group) end
    end
  end

  local nested_in = {}
  for _, outer in ipairs(all) do
    for _, inner in ipairs(all) do
      if inner ~= outer and not nested_in[outer] and outer.group.camera == inner.group.camera
      and area(outer.object.shape) > area(inner.object.shape)
      and outer.object.shape:is_colliding_with_point(inner.object.x, inner.object.y) then
        nested_in[inner] = outer
      end
    end
  end

  local candidates = {}
  for _, c in ipairs(all) do
    if not nested_in[c] then
      local nested = {}
      for inner, outer in pairs(nested_in) do
        if outer == c then table.insert(nested, inner) end
      end
      local x, y = c.object.x, c.object.y
      if #nested > 0 then x, y = aim_point(c, nested) end
      c.x, c.y = screen_position(c.group, x, y)
      table.insert(candidates, c)
    end
  end
  return candidates
end


-- Moves the mouse onto the best candidate in direction d; returns nothing.
local function move(d, scene_groups)
  local candidates = get_candidates(scene_groups)
  local mx, my = love.mouse.getPosition()
  local ox, oy = mx/sx, my/sy
  local focused
  for _, c in ipairs(candidates) do
    if c.object.colliding_with_mouse then focused = c; ox, oy = c.x, c.y; break end
  end

  -- Candidates within 45 degrees of the direction win over those merely ahead of it.
  local best_in_cone, cone_score, best_ahead, ahead_score, nearest, nearest_d
  for _, c in ipairs(candidates) do
    if c ~= focused then
      local dx, dy = c.x - ox, c.y - oy
      local along = dx*d[1] + dy*d[2]
      if along > 0 then
        local perpendicular = math.abs(dx*d[2] - dy*d[1])
        local score = along + perpendicular_weight*perpendicular
        if perpendicular <= along and (not cone_score or score < cone_score) then best_in_cone, cone_score = c, score end
        if not ahead_score or score < ahead_score then best_ahead, ahead_score = c, score end
      end
      local distance = dx*dx + dy*dy
      if not nearest_d or distance < nearest_d then nearest, nearest_d = c, distance end
    end
  end
  -- With nothing focused yet, any press lands on the closest object.
  local target = best_in_cone or best_ahead or (not focused and nearest)
  if not target then return end

  last_x, last_y = target.x*sx, target.y*sy
  love.mouse.setPosition(last_x, last_y)
  navigation.active = true
end


-- Reads direction input and moves focus, repeating while a direction is held.
-- scene_groups, when given, replaces the previous-tick groups as the candidate source.
function navigation.update(dt, scene_groups)
  if navigation.active then
    local mx, my = love.mouse.getPosition()
    if math.abs(mx - last_x) > 1 or math.abs(my - last_y) > 1 then navigation.active = false end
  end

  for name, d in pairs(directions) do
    local action = input['navigate_' .. name]
    if action.pressed then
      hold_timers[name] = repeat_delay
      move(d, scene_groups)
    elseif action.down then
      hold_timers[name] = hold_timers[name] - dt
      if hold_timers[name] <= 0 then
        hold_timers[name] = repeat_interval
        move(d, scene_groups)
      end
    end
  end
end
