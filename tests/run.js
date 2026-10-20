// Runs Lua test files in fengari with a `readfile(path)` global (fengari has
// no io.open). Usage: node tests/run.js tests/foo_test.lua [args...]

import fs from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const [file, ...args] = process.argv.slice(2);
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

lua.lua_pushjsfunction(L, (L) => {
  const path = to_jsstring(lauxlib.luaL_checkstring(L, 1));
  try {
    lua.lua_pushstring(L, to_luastring(fs.readFileSync(path, 'utf8')));
  } catch {
    lua.lua_pushnil(L);
  }
  return 1;
});
lua.lua_setglobal(L, to_luastring('readfile'));

// arg table like the standalone interpreter
lua.lua_createtable(L, args.length, 0);
args.forEach((a, i) => { lua.lua_pushstring(L, to_luastring(a)); lua.lua_rawseti(L, -2, i + 1); });
lua.lua_setglobal(L, to_luastring('arg'));

if (lauxlib.luaL_loadfile(L, to_luastring(file)) !== lua.LUA_OK || lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
  const msg = to_jsstring(lua.lua_tostring(L, -1));
  // os.exit inside Lua ends the process itself; anything else is a crash
  console.error(msg);
  process.exit(1);
}
