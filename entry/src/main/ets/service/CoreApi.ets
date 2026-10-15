import { http } from '@kit.NetworkKit';
import core from 'libhongflowbridge.so';

export class CoreApi {
  readonly secret: string;

  constructor(secret: string) {
    this.secret = secret;
  }

  async setMode(mode: string): Promise<void> {
    // ArkTS HTTP adds PATCH in API 26. The native client keeps mode switching
    // available on the API 22 baseline without relying on that newer transport.
    await core.setMode(mode, this.secret);
  }

  async request(path: string, method: http.RequestMethod = http.RequestMethod.GET,
    body: string = ''): Promise<string> {
    const client = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        usingCache: false,
        header: { 'Authorization': 'Bearer ' + this.secret, 'Content-Type': 'application/json' },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 3000,
        readTimeout: 8000
      };
      if (body.length > 0) {
        options.extraData = body;
      }
      const response = await client.request('http://127.0.0.1:9090' + path, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('内核请求失败 (' + response.responseCode + '): ' + String(response.result));
      }
      return String(response.result);
    } catch (error) {
      throw error as Error;
    } finally {
      client.destroy();
    }
  }
}
