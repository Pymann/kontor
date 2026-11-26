// Emscripten's Module for kontor-ui.js (doc/spec/web_ui.md §8).  A file of
// its own because kontor's CSP forbids inline scripts (FW-14).
var canvas = document.getElementById('canvas');
var statusLine = document.getElementById('status');
var Module = {
  canvas: canvas,
  print: function (text) { console.log(text); },
  printErr: function (text) { console.warn(text); },
  setStatus: function (text) {
    statusLine.textContent = text;
    statusLine.style.display = text ? 'block' : 'none';
  },
  onRuntimeInitialized: function () { Module.setStatus(''); canvas.focus(); },
  onAbort: function (what) { Module.setStatus('kontor UI stopped: ' + what); }
};
