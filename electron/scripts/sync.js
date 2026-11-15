// Copies the single shared wallpaper page into the Electron app so there is one source of truth.
const fs = require('fs');
const path = require('path');

const src = path.join(__dirname, '..', '..', 'examples', 'zenaquarium_worlds_live_wallpaper.html');
const dst = path.join(__dirname, '..', 'wallpaper.html');

if (!fs.existsSync(src)) {
  if (fs.existsSync(dst)) { console.log('sync: shared page not found, keeping existing wallpaper.html'); process.exit(0); }
  console.error('sync: cannot find ' + src); process.exit(1);
}
fs.copyFileSync(src, dst);
console.log('sync: wallpaper.html updated (' + fs.statSync(dst).size + ' bytes)');
