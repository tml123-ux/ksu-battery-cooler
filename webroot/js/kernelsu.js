// kernelsu bridge — classic-script 形式, 包装 KernelSU 注入的全局 ksu 对象
// 与官方 npm 包 kernelsu 的 JS API 保持一致, 免去打包/ESM 依赖
(function () {
  "use strict";
  var callbackCounter = 0;
  function getUniqueCallbackName(prefix) {
    return prefix + "_callback_" + Date.now() + "_" + callbackCounter++;
  }

  function exec(command, options) {
    if (typeof options === "undefined") { options = {}; }
    return new Promise(function (resolve, reject) {
      var cb = getUniqueCallbackName("exec");
      window[cb] = function (errno, stdout, stderr) {
        resolve({ errno: errno, stdout: stdout, stderr: stderr });
        delete window[cb];
      };
      try {
        ksu.exec(command, JSON.stringify(options), cb);
      } catch (e) {
        delete window[cb];
        reject(e);
      }
    });
  }

  function toast(message) {
    try { ksu.toast(message); } catch (e) {}
  }

  function fullScreen(on) {
    try { ksu.fullScreen(!!on); } catch (e) {}
  }

  function moduleInfo() {
    try { return ksu.moduleInfo(); } catch (e) { return null; }
  }

  window.kernelsu = {
    exec: exec,
    toast: toast,
    fullScreen: fullScreen,
    moduleInfo: moduleInfo
  };
})();
