export const validateProfile: (yaml: string) => Promise<string>;
export const start: (configPath: string, homeDir: string, tunFd: number, secret: string) => Promise<void>;
export const stop: () => Promise<void>;
export const tunInterfaceName: (fd: number) => string;
export const version: () => string;
export const setMode: (mode: string, secret: string) => Promise<void>;
