// Form validation. Messages are plain language and sit beside the field (UI_DESIGN.md section 5).
// The server validates again; this only gives fast feedback.
//
// validate(values, { name: { label: "Name", required: true, max: 80 }, ... })
//   -> { ok, errors: { name: "Name is required." } }
// rules: required, min, max (length), pattern + patternMessage, email, mobilePH, oneOf, custom(value, values)
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MOBILE_PH = /^(?:\+63|0)9\d{9}$/;

export function validate(values, schema) {
  const errors = {};
  for (const [field, rule] of Object.entries(schema)) {
    const label = rule.label ?? field;
    const raw = values[field];
    const value = typeof raw === "string" ? raw.trim() : raw;
    const empty = value === undefined || value === null || value === "";
    if (empty) {
      if (rule.required) errors[field] = `${label} is required.`;
      continue;
    }
    const text = String(value);
    if (rule.min && text.length < rule.min) {
      errors[field] = `${label} must be at least ${rule.min} characters.`;
    } else if (rule.max && text.length > rule.max) {
      errors[field] = `${label} must be at most ${rule.max} characters.`;
    } else if (rule.email && !EMAIL.test(text)) {
      errors[field] = `Enter a valid email address.`;
    } else if (rule.mobilePH && !MOBILE_PH.test(text.replace(/[\s-]/g, ""))) {
      errors[field] =
        `Enter a valid Philippine mobile number, like 09171234567.`;
    } else if (rule.pattern && !rule.pattern.test(text)) {
      errors[field] = rule.patternMessage ??
        `${label} is not in the expected format.`;
    } else if (rule.oneOf && !rule.oneOf.includes(value)) {
      errors[field] = `Choose a valid ${label.toLowerCase()}.`;
    } else if (rule.custom) {
      const message = rule.custom(value, values);
      if (message) errors[field] = message;
    }
  }
  return { ok: Object.keys(errors).length === 0, errors };
}
