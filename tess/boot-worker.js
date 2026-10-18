// Artifacts serve only web file types, so the language data ships as .wasm.
// Rewrite tesseract's request for it, then start the normal worker.
var _fetch = self.fetch.bind(self);
self.fetch = function (u, o) { return _fetch(String(u).replace(/\.traineddata$/, ".traineddata.wasm"), o); };
importScripts("worker.min.js");
