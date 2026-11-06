// Copy buttons for the install commands.
document.querySelectorAll(".copy").forEach(function (btn) {
  btn.addEventListener("click", function () {
    var code = document.getElementById(btn.dataset.copy);
    var text = code.textContent;
    var done = function () { btn.textContent = "Copied"; setTimeout(function () { btn.textContent = "Copy"; }, 1600); };
    var select = function () {
      var r = document.createRange(); r.selectNodeContents(code);
      var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      btn.textContent = "Selected";
      setTimeout(function () { btn.textContent = "Copy"; }, 1600);
    };
    try {
      navigator.clipboard.writeText(text).then(done, select);
    } catch (e) { select(); }
  });
});
