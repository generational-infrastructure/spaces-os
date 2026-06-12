import * as React from "react";
import type { IconName } from "./Icon";

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** Optional leading icon. */
  icon?: IconName;
  /** primary = filled chartreuse (default), neutral = raised surface, danger = error fill. */
  variant?: "primary" | "neutral" | "danger";
}

/**
 * Pill button with a 1px outline; hover brightens the fill.
 */
export declare function Button(props: ButtonProps): React.ReactElement;
