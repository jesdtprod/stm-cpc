// Shared by text buttons, icon buttons and modal actions.
const VARIANTS = new Set([
  "primary",
  "secondary",
  "accent",
  "danger",
  "warning",
  "success",
  "info",
  "archive",
  "restore",
  "edit",
  "outline",
  "ghost",
  "link",
]);

export function buttonClasses(
  { variant = "secondary", size = "default", iconOnly = false } = {},
) {
  const tone = variant === "destructive"
    ? "danger"
    : variant === "amber"
    ? "accent"
    : variant;
  return [
    "btn",
    `btn-${VARIANTS.has(tone) ? tone : "secondary"}`,
    iconOnly ? "btn-icon" : null,
    size === "sm" ? "btn-sm" : size === "lg" ? "btn-lg" : null,
  ].filter(Boolean).join(" ");
}
