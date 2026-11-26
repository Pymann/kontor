// Emscripten's Module for kontor-ui.js (doc/spec/web_ui.md §8).  A file of
// its own because kontor's CSP forbids inline scripts (FW-14).
var canvas = document.getElementById('canvas');
var statusLine = document.getElementById('status');
// The canvas' backing store has to be as large as the page shows it: the
// engine reads its size as the window size (aiml engine_runtime), and with
// the default 300x150 the whole UI was drawn small and stretched.  One
// backing pixel per CSS pixel, so the UI's 15 px font stays 15 px.
function fitCanvas() {
  var w = Math.max(1, Math.round(canvas.clientWidth || window.innerWidth));
  var h = Math.max(1, Math.round(canvas.clientHeight || window.innerHeight));
  if (canvas.width !== w) canvas.width = w;
  if (canvas.height !== h) canvas.height = h;
}
fitCanvas();
window.addEventListener('resize', fitCanvas);
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
