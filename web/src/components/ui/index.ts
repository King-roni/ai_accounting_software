// Core component library (R1.2, impl of B16·P04). Primitives consume R1.1
// design tokens. Shell chrome (Top Nav, Sidebar, Command Palette) lives in R1.3;
// Storybook + visual regression in R3.
export { Button, type ButtonProps, type ButtonVariant, type ButtonSize } from "./Button";
export { Badge, type BadgeProps, type BadgeVariant, type BadgeSize } from "./Badge";
export { Alert, type AlertProps, type AlertVariant } from "./Alert";
export { Card, CardHeader, CardTitle, CardBody, CardFooter, type CardProps, type CardAccent } from "./Card";
export { Skeleton, SkeletonText, type SkeletonProps } from "./Skeleton";
export { EmptyState, ErrorState, type EmptyStateProps, type ErrorStateProps } from "./States";
export { Input, type InputProps } from "./Input";
export { Textarea, type TextareaProps } from "./Textarea";
export { Select, type SelectProps } from "./Select";
export { Tabs, type TabsProps, type TabItem } from "./Tabs";
export { Modal, type ModalProps } from "./Modal";
export { Drawer, type DrawerProps } from "./Drawer";
export { Table, type TableProps, type Column } from "./Table";
export { ToastProvider, useToast, type ToastOptions, type ToastVariant } from "./Toast";
export { Popover, MenuItem, type PopoverProps } from "./Popover";
