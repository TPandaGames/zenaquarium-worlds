'use strict';
// Minimal, isolated bridge: the page can only report its tank state to the host.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('zenHost', {
  state: (msg) => { if (typeof msg === 'string' && msg.length < 4096) ipcRenderer.send('zen:state', msg); }
});
