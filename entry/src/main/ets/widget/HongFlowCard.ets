const storage: LocalStorage = new LocalStorage();

/** Separate app navigation from background control; VPN state is supplied by the app. */
@Entry(storage)
@Component
struct HongFlowCard {
  @LocalStorageProp('phase') phase: string = 'idle';
  @LocalStorageProp('statusLabel') statusLabel: string = '请先导入配置';
  @LocalStorageProp('action') action: string = 'none';
  @LocalStorageProp('actionLabel') actionLabel: string = '请先在应用中导入配置';
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('cardToken') cardToken: string = '';
  @LocalStorageProp('requestId') requestId: string = '';

  build() {
    Stack() {
      Image($r('app.media.card_flow_background'))
      // Finish decoding this small local SVG before the static card takes its snapshot.
        .syncLoad(true)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Fill)
        .accessibilityLevel('no')

      // Static cards use adjacent FormLink hit regions, so opening the app cannot
      // also issue a connection command. The background does not handle input.
      Row() {
        FormLink({
          action: 'router',
          moduleName: 'entry',
          abilityName: 'EntryAbility',
        }) {
          Column({ space: $r('app.float.card_text_gap') }) {
            Text($r('app.string.card_title'))
              .fontSize($r('app.float.card_title_size'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.card_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row({ space: $r('app.float.card_status_gap') }) {
              Row()
                .width($r('app.float.card_status_indicator_width'))
                .height($r('app.float.card_status_indicator_height'))
                .borderRadius($r('app.float.card_status_indicator_radius'))
                .backgroundColor(this.phase === 'connected' ? $r('app.color.card_connected_accent') :
                  this.phase === 'error' ? $r('app.color.status_warning') : $r('app.color.card_text_secondary'))
              Text(this.action === 'none' ? $r('app.string.card_add_configuration') : this.statusLabel)
                .fontSize($r('app.float.card_body_size'))
                .fontColor(this.phase === 'connected' ? $r('app.color.card_connected_accent') :
                  this.phase === 'error' ? $r('app.color.status_warning') : $r('app.color.card_text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height('100%')
          .padding({
            left: $r('app.float.card_padding'),
            right: $r('app.float.card_content_gap'),
            top: $r('app.float.card_vertical_padding'),
            bottom: $r('app.float.card_vertical_padding'),
          })
        }
        .layoutWeight(1)
        .height('100%')
        .accessibilityGroup(true)
        .accessibilityText('鸿流，' + this.statusLabel + '，打开应用')

        // Only this control carries the token and explicit start/stop target.
        // The full-height edge area makes the small 1x2 control easier to hit.
        FormLink({
          action: 'call',
          moduleName: 'entry',
          abilityName: 'EntryAbility',
          params: {
            method: 'controlVpn',
            cardAction: this.action,
            cardId: this.formId,
            cardToken: this.cardToken,
            cardRequestId: this.requestId,
          },
        }) {
          Row() {
            // The visual control is smaller; its existing full-height hit area stays unchanged.
            Stack() {
              Row() {
                SymbolGlyph($r('sys.symbol.power'))
                  .fontSize($r('app.float.card_icon_size'))
                  .fontColor([this.action === 'none' ? $r('app.color.card_text_secondary') :
                    this.phase === 'connected' ? $r('app.color.card_control_connected_foreground') :
                      $r('app.color.card_control_foreground')])
              }
              .justifyContent(FlexAlign.Center)
              .width($r('app.float.card_control_size'))
              .height($r('app.float.card_control_size'))
              .borderRadius($r('app.float.card_control_radius'))
              .backgroundColor(this.phase === 'connected' ? $r('app.color.card_control_connected') :
                $r('app.color.card_control_idle'))
            }
            .width($r('app.float.card_button_size'))
            .height($r('app.float.card_button_size'))
          }
          .height('100%')
          .padding({ right: $r('app.float.card_padding') })
        }
        .height('100%')
        .enabled(this.action !== 'none')
        .accessibilityGroup(true)
        .accessibilityText(this.statusLabel + '，' + this.actionLabel)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    // The artwork fills the card; the desktop supplies its outer rounded shape.
    .clip(true)
  }
}
