// Origin comes from Chrome's sender, never from a page or a message payload.
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id || !sender.tab || sender.frameId !== 0 ||
      !sender.url?.startsWith("https://") || !["accounts", "fill"].includes(message?.action) ||
      !["username", "password", "otp_code"].includes(message.field)) return;
  const origin = new URL(sender.url).origin;
  if (sender.origin !== origin) return;
  const request = {origin, action: message.action};
  if (message.action === "fill") {
    Object.assign(request, {field: message.field, id: message.id, revision: message.revision});
  }
  chrome.runtime.sendNativeMessage("com.boreas.aksk_manager", request).then(result => {
    if (!result?.ok) return reply(null);
    reply(message.action === "accounts" ? result.data.filter(a => a.fields.includes(message.field))
      .map(({id, revision, name}) => ({id, revision, name})) : result.data);
  }).catch(() => reply(null));
  return true;
});
