import * as React from "react";

export type DotStatus = "online" | "offline" | "working" | "idle" | "error";

export interface StatusDotProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** online=mint, offline/error=pink, working=chartreuse (pulses), idle=muted. */
  status?: DotStatus;
  /** Diameter in px. Default 8. */
  size?: number;
}

/** Small colour-coded live-state dot; `working` pulses. */
export declare function StatusDot(props: StatusDotProps): React.ReactElement;
