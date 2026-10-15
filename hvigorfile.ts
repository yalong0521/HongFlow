import { FileUtil, hvigor } from '@ohos/hvigor';
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';

hvigor.afterNodeEvaluate((node) => {
  const context = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext | undefined;
  if (context === undefined) {
    return;
  }
  const localPath = FileUtil.pathResolve(context.getProjectPath(), 'build-profile.local.json5');
  if (!FileUtil.exist(localPath)) {
    return;
  }
  const local = FileUtil.readJson5(localPath);
  if (!Array.isArray(local.app?.signingConfigs) || !Array.isArray(local.app?.products)) {
    throw new Error('本地签名配置需要包含 app.signingConfigs 和 app.products');
  }
  const profile = context.getBuildProfileOpt();
  // 只在构建内存中合并签名，不把本机材料回写公共配置，也不覆盖 SDK/产品设置。
  profile.app.signingConfigs = local.app.signingConfigs;
  for (const product of profile.app.products) {
    const signing = local.app.products.find((item: { name: string; signingConfig?: string }) =>
      item.name === product.name);
    if (signing?.signingConfig !== undefined) {
      product.signingConfig = signing.signingConfig;
    }
  }
  context.setBuildProfileOpt(profile);
});

export default { system: appTasks, plugins: [] };
