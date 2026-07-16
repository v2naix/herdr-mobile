(root => {
  'use strict';

  function shouldReconnect({manuallyLoggedOut, closeCode}) {
    return !manuallyLoggedOut && closeCode !== 1008;
  }

  const api = {shouldReconnect};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.HerdrReconnectPolicy = api;
})(globalThis);
