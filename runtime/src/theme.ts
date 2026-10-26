// Color/spacing direction follows Tempo; implementation is independent.
export function palette(dark: boolean) {
  return {
    background: dark ? '#0B0B0B' : '#F3F4F5', surface: dark ? '#171717' : '#FFFFFF',
    ink: dark ? '#F5F5F5' : '#1A1C1F', quiet: dark ? '#A3A3A3' : '#74777C',
    separator: dark ? '#303030' : '#E4E5E7', accent: '#339CFF',
    warning: dark ? '#E8AF57' : '#8A6200', success: dark ? '#56C596' : '#2E7D64',
  };
}
export const layout = { inset: 16, gap: 10, radius: 16, cardInset: 14 };
