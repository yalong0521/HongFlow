import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import native from 'libhongflowbridge.so';
import { ValidationResult } from '../model/AppModels';

export const MAX_PROFILE_BYTES: number = 5 * 1024 * 1024;

/** 手动导入和系统后台检查使用相同的下载边界与内核校验。 */
export class SubscriptionService {
  private client?: http.HttpRequest;
  private generation: number = 0;

  async download(url: string): Promise<string> {
    this.cancel();
    const generation = this.generation;
    const client = http.createHttp();
    this.client = client;
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        usingCache: false,
        header: { 'User-Agent': 'ClashMeta HongFlow/0.1.0', 'Accept': 'text/yaml, text/plain, */*' },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 20000,
        maxLimit: MAX_PROFILE_BYTES
      };
      const response = await client.request(SubscriptionService.checkedUrl(url), options);
      if (generation !== this.generation) {
        throw new Error('订阅下载已取消');
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('订阅下载失败 (' + response.responseCode + ')');
      }
      const bytes = response.result as ArrayBuffer;
      if (bytes.byteLength === 0 || bytes.byteLength > MAX_PROFILE_BYTES) {
        throw new Error('订阅内容为空或超过 5 MB');
      }
      return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(bytes));
    } catch (error) {
      throw error as Error;
    } finally {
      if (this.client === client) {
        this.client = undefined;
        client.destroy();
      }
    }
  }

  cancel(): void {
    this.generation += 1;
    const client = this.client;
    this.client = undefined;
    try {
      client?.destroy();
    } catch (_) {
      // 系统停止后台任务时仍要使本次请求失效，销毁失败不允许迟到结果继续保存。
    }
  }

  static checkedUrl(value: string): string {
    const url = value.trim();
    if (!/^https?:\/\/[^\s]+$/i.test(url)) {
      throw new Error('请输入 http 或 https 开头的订阅链接');
    }
    return url;
  }

  static async validate(yaml: string): Promise<ValidationResult> {
    if (yaml.length === 0 || util.TextEncoder.create().encodeInto(yaml).byteLength > MAX_PROFILE_BYTES) {
      throw new Error('配置内容为空或超过 5 MB');
    }
    const result = JSON.parse(await native.validateProfile(yaml)) as ValidationResult;
    if (!result.valid) {
      throw new Error(result.error || '配置校验失败，请使用兼容的 YAML 配置');
    }
    return result;
  }
}
