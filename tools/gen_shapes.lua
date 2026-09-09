-- tools/gen_shapes.lua — draws Elmira/media/shape_*.tga, the shipped indicator shapes (AB3-D1).
--
-- Run once, by hand, and commit the output:
--
--     lua5.1 tools/gen_shapes.lua
--
-- WHY A GENERATOR AND NOT EIGHT BINARIES SOMEONE DREW. A shape file is opaque in review and in a
-- diff: "the ring got thinner" is a change nobody can see in a pull request, and nobody can redo
-- either, because the settings that produced it lived in whichever image editor was open that day.
-- The geometry is here in numbers instead, so changing a radius is a one-line diff and re-running
-- this is the whole build step.
--
-- WHITE WITH ALPHA, deliberately. Every pixel is pure white and the SHAPE is carried entirely by
-- the alpha channel, which is what lets Display/Textures.lua tint one file to whatever colour the
-- player picked with SetVertexColor. A shape baked in colour would need one file per colour.
--
-- FORMAT: 32-bit uncompressed TGA, top-left origin, BGRA byte order -- byte for byte the header the
-- media already in this folder carries (`flare_h.tga`, `mark_*.tga`), which is the only format the
-- Classic client is known here to load from an addon folder. Verified by comparing the first 18
-- bytes of the output against those files, not assumed.
local SIZE = 64          -- power of two; the client rejects textures that are not
local SUPERSAMPLE = 4    -- 4x4 samples per pixel: the edges are curved, and a hard 1-bit edge on a
                         -- 64px ring reads as a staircase at any size the player scales it to
local OUT = "Elmira/media/"

-- Point-in-polygon by the crossing rule, which handles the concave shapes (star, chevron, arrow)
-- the same way it handles convex ones -- so there is one test here rather than one per shape.
local function inside(poly, x, y)
  local n, hit = #poly, false
  local j = n
  for i = 1, n do
    local xi, yi = poly[i][1], poly[i][2]
    local xj, yj = poly[j][1], poly[j][2]
    if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then
      hit = not hit
    end
    j = i
  end
  return hit
end

local function polygon(points)
  return function(x, y) return inside(points, x, y) end
end

-- Ten vertices alternating tip and valley, first tip straight up.
local function starPoints(outer, inner)
  local pts = {}
  for i = 0, 9 do
    local angle = math.pi / 2 + i * math.pi / 5
    local r = (i % 2 == 0) and outer or inner
    pts[#pts + 1] = { r * math.cos(angle), r * math.sin(angle) }
  end
  return pts
end

-- Every shape is a predicate over the square [-1,1]^2. Coordinates are normalised rather than in
-- pixels so SIZE can change without touching a single number below.
local SHAPES = {
  ring = function(x, y)
    local r = math.sqrt(x * x + y * y)
    return r <= 0.95 and r >= 0.63
  end,
  disc = function(x, y) return (x * x + y * y) <= 0.9025 end,
  square = function(x, y) return math.abs(x) <= 0.88 and math.abs(y) <= 0.88 end,
  diamond = function(x, y) return (math.abs(x) + math.abs(y)) <= 0.98 end,
  bar = function(x, y) return math.abs(x) <= 0.96 and math.abs(y) <= 0.24 end,
  arrow = polygon({ { 0, 0.95 }, { 0.75, 0.15 }, { 0.32, 0.15 }, { 0.32, -0.95 },
                    { -0.32, -0.95 }, { -0.32, 0.15 }, { -0.75, 0.15 } }),
  -- A BAND, not a filled triangle: the inner apex (0, 0.35) sits ABOVE the inner ends, so the
  -- bottom edge follows the top one down and out instead of dipping between them. Vertically
  -- centred on the band, not on the outer apex, or the shape sits in the top third of its own box.
  chevron = polygon({ { 0, 0.85 }, { 0.95, -0.25 }, { 0.95, -0.75 }, { 0, 0.35 },
                      { -0.95, -0.75 }, { -0.95, -0.25 } }),
  star = polygon(starPoints(0.97, 0.44)),
}

local function header(size)
  local lo = size % 256
  local hi = math.floor(size / 256)
  return string.char(
    0, 0, 2,                 -- no id field, no colour map, uncompressed true-colour
    0, 0, 0, 0, 0,           -- colour map specification, unused
    0, 0, 0, 0,              -- x/y origin
    lo, hi, lo, hi,          -- width, height (little-endian)
    32,                      -- bits per pixel
    0x28)                    -- 8 alpha bits, top-left origin
end

-- Alpha for one pixel: the fraction of its SUPERSAMPLE^2 sample points that land inside the shape.
local function coverage(shape, px, py)
  local hits, total = 0, SUPERSAMPLE * SUPERSAMPLE
  for sy = 0, SUPERSAMPLE - 1 do
    for sx = 0, SUPERSAMPLE - 1 do
      local fx = (px + (sx + 0.5) / SUPERSAMPLE) / SIZE * 2 - 1
      -- The image runs top-down (top-left origin) and the shape maths runs y-up, so the row index
      -- is flipped here. Without it every asymmetric shape ships upside down -- which is exactly
      -- the kind of thing that looks fine in a hex dump.
      local fy = 1 - (py + (sy + 0.5) / SUPERSAMPLE) / SIZE * 2
      if shape(fx, fy) then hits = hits + 1 end
    end
  end
  return math.floor(hits / total * 255 + 0.5)
end

local function write(name, shape)
  local path = OUT .. "shape_" .. name .. ".tga"
  local f = assert(io.open(path, "wb"), "cannot write " .. path)
  f:write(header(SIZE))
  -- One string.char per pixel would be 4096 concatenations per row; a table joined once per row
  -- keeps a full run under a second even with 16 samples per pixel.
  for py = 0, SIZE - 1 do
    local row = {}
    for px = 0, SIZE - 1 do
      local a = coverage(shape, px, py)
      row[#row + 1] = string.char(255, 255, 255, a) -- BGRA, white
    end
    f:write(table.concat(row))
  end
  f:close()
  print(string.format("wrote %s (%dx%d)", path, SIZE, SIZE))
end

local names = {}
for name in pairs(SHAPES) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do write(name, SHAPES[name]) end
