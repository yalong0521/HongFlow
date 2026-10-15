interface LayoutDesignTokens {
  readonly pageCompact: number;
  readonly pageRegular: number;
  readonly sectionGap: number;
  readonly cardPadding: number;
  readonly surfaceRadius: number;
  readonly nodeRadius: number;
  readonly nodeRowMinHeight: number;
  readonly nodeRowCompactMinHeight: number;
  readonly overviewMaxWidth: number;
  readonly listMaxWidth: number;
  readonly wideMinWidth: number;
  readonly railWidth: number;
  readonly tabBarHeight: number;
  readonly floatingBarBottomMargin: number;
  readonly headingSize: number;
  readonly headingDetailSize: number;
  readonly rowMinHeight: number;
}

interface ThemeDesignTokens {
  readonly background: ResourceColor;
  readonly surface: ResourceColor;
  readonly surfaceSubtle: ResourceColor;
  readonly textPrimary: ResourceColor;
  readonly textSecondary: ResourceColor;
  readonly accent: ResourceColor;
  readonly selected: ResourceColor;
  readonly warning: ResourceColor;
  readonly success: ResourceColor;
  readonly actionBackground: ResourceColor;
  readonly actionForeground: ResourceColor;
}

/** 布局尺寸均为 vp；导航根据真实可用窗口宽度切换，内容栅格根据自身宽度分列。 */
export const LayoutTokens: LayoutDesignTokens = {
  pageCompact: 16,
  pageRegular: 24,
  sectionGap: 24,
  cardPadding: 20,
  surfaceRadius: 20,
  nodeRadius: 12,
  nodeRowMinHeight: 72,
  nodeRowCompactMinHeight: 64,
  overviewMaxWidth: 1200,
  listMaxWidth: 720,
  wideMinWidth: 840,
  railWidth: 104,
  tabBarHeight: 64,
  floatingBarBottomMargin: 8,
  headingSize: 28,
  headingDetailSize: 14,
  rowMinHeight: 64,
};

// 保留 ResourceColor 引用，由系统在绘制时解析深浅色，不缓存解析后的 RGB 值。
export const ThemeTokens: ThemeDesignTokens = {
  background: $r('sys.color.background_secondary'),
  surface: $r('sys.color.comp_background_list_card'),
  surfaceSubtle: $r('sys.color.ohos_id_color_background'),
  textPrimary: $r('sys.color.font_primary'),
  textSecondary: $r('sys.color.font_secondary'),
  accent: $r('sys.color.font_emphasize'),
  selected: $r('sys.color.interactive_select'),
  warning: $r('app.color.status_warning'),
  success: $r('app.color.status_positive'),
  actionBackground: $r('app.color.primary_action_background'),
  actionForeground: $r('app.color.primary_action_foreground'),
};
