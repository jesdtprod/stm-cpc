import { buttonClasses } from "../../web/lib/buttons.js";

Deno.test("buttons: text and icon actions share every semantic variant", () => {
  for (
    const variant of [
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
    ]
  ) {
    const text = buttonClasses({ variant });
    const icon = buttonClasses({ variant, iconOnly: true });
    if (icon !== `${text} btn-icon`) {
      throw new Error(`Inconsistent variant: ${variant}`);
    }
  }
});

Deno.test("buttons: aliases, sizes and unsupported variants remain consistent", () => {
  const cases = [
    [{ variant: "destructive" }, "btn btn-danger"],
    [{ variant: "amber" }, "btn btn-accent"],
    [{ variant: "unknown" }, "btn btn-secondary"],
    [
      { variant: "success", size: "sm", iconOnly: true },
      "btn btn-success btn-icon btn-sm",
    ],
    [{ size: "lg" }, "btn btn-secondary btn-lg"],
  ];
  for (const [input, expected] of cases) {
    if (buttonClasses(input) !== expected) {
      throw new Error(`Unexpected classes for ${JSON.stringify(input)}`);
    }
  }
});
