(function () {
  var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.__SHY_NAME__;
  if (!handler || Object.prototype.hasOwnProperty.call(window, '__bridged')) return;
  window.__bridged = true;
  window.addEventListener('__SHY_ASKED__', function (event) {
    var message;
    try { message = JSON.parse(event.detail); } catch (e) { return; }
    if (!message || typeof message !== 'object' || typeof message.token !== 'string') return;
    function answer(reply) {
      window.dispatchEvent(new CustomEvent('__SHY_ANSWERED__', { detail: JSON.stringify({ token: message.token, reply: reply }) }));
    }
    handler.postMessage(message).then(function (reply) {
      if (message.kind !== 'cancel') answer(reply);
    }, function () {
      if (message.kind !== 'cancel') answer(null);
    });
  });
})();
