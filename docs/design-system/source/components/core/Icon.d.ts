import * as React from "react";

export type IconName =
  | "brain" | "check" | "chevron-down" | "chevron-up" | "corner-down-right"
  | "database-off" | "dots-vertical" | "edit" | "eraser" | "eye-off" | "eye"
  | "gauge" | "key" | "message-chatbot" | "message-circle-off" | "message-circle"
  | "microphone-off" | "microphone" | "paperclip" | "plus" | "rotate" | "search"
  | "send" | "settings" | "sparkles" | "x";

export interface IconProps extends React.SVGProps<SVGSVGElement> {
  /** Tabler outline icon name (matches the vendored SVG filenames). */
  name: IconName;
  /** Square pixel size. Default 20. */
  size?: number;
  /** Stroke width on the 24px grid. Default 2 (Tabler outline weight). */
  strokeWidth?: number;
  /** Accessible label; when omitted the glyph is aria-hidden. */
  title?: string;
}

/** The vendored Tabler outline set, drawn in currentColor. */
export declare const ICON_PATHS: Record<IconName, string>;

/**
 * Spaces OS icon. Inline SVG so it inherits the surrounding `color`.
 */
export declare function Icon(props: IconProps): React.ReactElement | null;
