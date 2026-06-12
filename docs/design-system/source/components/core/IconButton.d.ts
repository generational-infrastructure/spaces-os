import * as React from "react";
import type { IconName } from "./Icon";

export interface IconButtonProps extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "title"> {
  /** Tabler icon name. */
  icon: IconName;
  /** Square size in px. Default 33 (the panel's baseWidgetSize). */
  size?: number;
  /** Armed/recording state — flips the chip to error-red. */
  active?: boolean;
  /** Tooltip + accessible label. */
  title?: string;
}

/**
 * Square icon control; hover flips the chip to the mint hover fill.
 */
export declare function IconButton(props: IconButtonProps): React.ReactElement;
