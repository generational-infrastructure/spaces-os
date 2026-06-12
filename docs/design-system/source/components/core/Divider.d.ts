import * as React from "react";

export interface DividerProps extends React.HTMLAttributes<HTMLDivElement> {
  vertical?: boolean;
}

/** 1px hairline divider in the outline colour. */
export declare function Divider(props: DividerProps): React.ReactElement;
