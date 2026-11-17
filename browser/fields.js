globalThis.akskFieldOf = function(input) {
    if (!(input instanceof HTMLInputElement) || input.disabled || input.readOnly ||
        !input.isConnected || !input.checkVisibility() ||
        (input.form && new URL(input.form.action || location.href).origin !== location.origin)) return;
    const tokens = input.autocomplete.toLowerCase().split(/\s+/);
    if (tokens.includes("new-password") || tokens.some(t => t.startsWith("cc-"))) return;
    if (tokens.includes("one-time-code")) return "otp_code";
    const labels = Array.from(input.labels || [], l => l.textContent.trim());
    const hints = [input.name, input.id, input.getAttribute("aria-label"), ...labels].filter(Boolean);
    // Match explicit authentication terms, never a bare "code" or a generated ID.
    if (["text","tel","number","password"].includes(input.type) &&
        [...hints, input.placeholder].some(s =>
          /^(?:(?:mfa|2fa|totp|otp)(?:[ _-]*(?:code|token))?|one[ -]time[ -](?:code|passcode)|authenticator[ -]code|动态验证码|动态口令)$/i.test(s.trim()))) return "otp_code";
    if (input.type === "password") return "password";
    if (!["text","email","tel"].includes(input.type)) return;
    if (tokens.includes("username") || input.type === "email" ||
        hints.some(s => /^(user(name)?|email|login(name)?|account(name)?|用户名|账号)$/i.test(s))) return "username";
    // A bare ID is ambiguous outside a login form (order IDs, customer IDs, etc.).
    if (labels.some(s => /^id$/i.test(s)) && input.form &&
        Array.from(input.form.elements).some(p => p.type === "password" && !p.disabled &&
          p.checkVisibility() && !p.autocomplete.split(/\s+/).includes("new-password"))) return "username";
  };
