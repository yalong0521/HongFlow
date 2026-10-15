import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VpnCardService } from '../service/VpnCardService';

export default class HongFlowFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = want.parameters?.[formInfo.FormParam.IDENTITY_KEY];
    if (typeof formId !== 'string' || formId.length === 0) {
      hilog.error(0x0000, 'HongFlowForm', '添加卡片失败：卡片标识无效');
      return formBindingData.createFormBindingData({});
    }
    try {
      return formBindingData.createFormBindingData(new VpnCardService(this.context).addForm(formId));
    } catch (_error) {
      // Do not print form payloads: they contain a private card control token.
      hilog.error(0x0000, 'HongFlowForm', '添加桌面卡片失败');
      return formBindingData.createFormBindingData({});
    }
  }

  onUpdateForm(formId: string): void {
    this.updateCard(formId);
  }

  onCastToNormalForm(formId: string): void {
    this.updateCard(formId);
  }

  onChangeFormVisibility(newStatus: Record<string, number>): void {
    for (const formId of Object.keys(newStatus)) {
      if (newStatus[formId] === formInfo.VisibilityType.FORM_VISIBLE) {
        this.updateCard(formId);
      }
    }
  }

  onRemoveForm(formId: string): void {
    try {
      new VpnCardService(this.context).removeForm(formId);
    } catch (_error) {
      hilog.warn(0x0000, 'HongFlowForm', '移除桌面卡片数据失败');
    }
  }

  onAcquireFormState(_want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  private updateCard(formId: string): void {
    try {
      new VpnCardService(this.context).updateForm(formId).catch(() => {
        hilog.warn(0x0000, 'HongFlowForm', '更新桌面卡片失败');
      });
    } catch (_error) {
      hilog.warn(0x0000, 'HongFlowForm', '更新桌面卡片失败');
    }
  }
}
