// Native host navigation; all book text and ruby are drawn by libxy.
// Included inside XyCanvasView's implementation so document/source ownership stays explicit.
- (NSButton *)homeButton:(NSString *)title action:(SEL)action frame:(NSRect)frame parent:(NSView *)parent {
    NSButton *b = [[NSButton alloc] initWithFrame:frame];
    b.title = title; b.bezelStyle = NSBezelStyleRounded; b.target = self; b.action = action;
    if (parent != _home && parent != _readingBar) b.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [parent addSubview:b]; return b;
}
- (NSTextField *)homeLabel:(NSString *)text size:(CGFloat)size frame:(NSRect)frame parent:(NSView *)parent {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:NSFontWeightRegular];
    label.textColor = [NSColor colorWithCalibratedRed:0.16 green:0.20 blue:0.19 alpha:1];
    label.frame = frame; [parent addSubview:label]; return label;
}
- (void)loadLibrary {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"library" ofType:@"json"];
    if (!path) path = [[[NSProcessInfo processInfo].arguments[0] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"library.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *pack = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if ([pack isKindOfClass:[NSDictionary class]] && [pack[@"version"] isEqual:@1] && [pack[@"items"] isKindOfClass:[NSArray class]]) _library = pack[@"items"];
    else _library = @[];
    NSString *learningPath=[[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"learning.pack"];
    _learningData=[NSData dataWithContentsOfFile:learningPath];
    if (!_learningData || !data || !xy_host_learning_bind(_learningData.bytes,(uint32_t)_learningData.length,data.bytes,(uint32_t)data.length)) _learningData=nil;

}
- (void)installHomeIn:(NSView *)root {
    [self loadLibrary];
    CGFloat w = NSWidth(root.bounds), h = NSHeight(root.bounds);
    _home = [[NSView alloc] initWithFrame:root.bounds];
    _home.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _home.wantsLayer = YES;
    _home.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.97 green:0.96 blue:0.93 alpha:1].CGColor;
    [root addSubview:_home];
    root.wantsLayer=YES; root.layer.backgroundColor=[NSColor colorWithCalibratedRed:0.92 green:0.91 blue:0.88 alpha:1].CGColor;
    NSView *rail = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 208, h)];
    rail.wantsLayer = YES;
    rail.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.15 green:0.25 blue:0.23 alpha:1].CGColor;
    [_home addSubview:rail];
    NSTextField *logo = [self homeLabel:@"xy" size:48 frame:NSMakeRect(28, h-102, 160, 65) parent:rail];
    logo.font = [NSFont systemFontOfSize:48 weight:NSFontWeightLight]; logo.textColor = NSColor.whiteColor;
    NSTextField *tag = [self homeLabel:@"読む。書く。試す。" size:14 frame:NSMakeRect(28, h-127, 170, 25) parent:rail];
    tag.textColor = [NSColor colorWithCalibratedWhite:0.83 alpha:1];
    [self homeButton:@"新規ファイル  ⌘N" action:@selector(newDocument:) frame:NSMakeRect(22, h-198, 164, 34) parent:rail];
    [self homeButton:@"ファイルを開く  ⌘O" action:@selector(openDocument:) frame:NSMakeRect(22, h-244, 164, 34) parent:rail];
    [self homeButton:@"編集中の文書に戻る" action:@selector(resumeDocument:) frame:NSMakeRect(22, h-290, 164, 34) parent:rail];
    _resumeReadingButton=[self homeButton:@"読んでいた本に戻る" action:@selector(resumeReading:) frame:NSMakeRect(22,h-336,164,34) parent:rail];
    for (NSView *child in rail.subviews) if ([child isKindOfClass:[NSButton class]]) ((NSButton *)child).appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSTextField *foot = [self homeLabel:@"A small place\nto grow your ideas." size:13 frame:NSMakeRect(28, 28, 160, 50) parent:rail];
    foot.textColor = [NSColor colorWithCalibratedWhite:0.8 alpha:1];
    CGFloat x = 244, cw = (w-x-50)/2;
    [self homeLabel:@"ようこそ、xyへ。" size:30 frame:NSMakeRect(x, h-81, w-x-24, 44) parent:_home];
    [self homeLabel:@"小さな文章から、新しい考えを。" size:14 frame:NSMakeRect(x, h-112, w-x-24, 26) parent:_home];
    [self homeLabel:@"はじめる・本棚" size:15 frame:NSMakeRect(x, h-159, w-x-24, 25) parent:_home];
    NSArray *titles = @[@"01    xyを使ってみる", @"02    草枕", @"03    SICP", @"04    小さなOSを育てる"];
    NSArray *descriptions = @[@"書く・読む・Schemeの3レッスン", @"夏目漱石 · 青空文庫 · ルビ付き", @"英語原文 · 式と再帰のサンプル", @"この端末を知る、リポジトリの書籍"];
    for (NSUInteger i=0; i<4; i++) {
        CGFloat cx=x+(i%2)*(cw+16), cy=h-258-(i/2)*102;
        NSView *card = [[NSView alloc] initWithFrame:NSMakeRect(cx, cy, cw, 90)];
        card.wantsLayer=YES; card.layer.cornerRadius=10;
        card.layer.backgroundColor=NSColor.whiteColor.CGColor;
        [_home addSubview:card];
        NSButton *b = [self homeButton:titles[i] action:@selector(selectHomeBook:) frame:NSMakeRect(12, 44, cw-24, 34) parent:card];
        b.tag=(NSInteger)i; b.enabled = _library.count == 4;
        [self homeLabel:descriptions[i] size:11 frame:NSMakeRect(16, 14, cw-28, 25) parent:card];
    }
    [self homeLabel:@"表示設定" size:15 frame:NSMakeRect(x, h-404, w-x-24, 25) parent:_home];
    _directionPicker = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(x, h-444, 170, 30)];
    _directionPicker.segmentCount=2;
    [_directionPicker setLabel:@"横書き" forSegment:0]; [_directionPicker setLabel:@"縦書き" forSegment:1];
    _directionPicker.target=self; _directionPicker.action=@selector(homeSettingsChanged:); [_home addSubview:_directionPicker];
    _sizePicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(x+184, h-444, 120, 30)];
    for (NSNumber *n in @[@16,@20,@24,@28,@32,@36,@40,@48,@56,@64]) [_sizePicker addItemWithTitle:[NSString stringWithFormat:@"文字 %@ px",n]];
    _sizePicker.target=self; _sizePicker.action=@selector(homeSettingsChanged:); [_home addSubview:_sizePicker];
    _familyPicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(x+318, h-444, 120, 30)];
    [_familyPicker addItemsWithTitles:@[@"明朝",@"ゴシック"]]; _familyPicker.target=self; _familyPicker.action=@selector(homeSettingsChanged:); [_home addSubview:_familyPicker];
    _themePicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(x+452, h-444, 130, 30)];
    [_themePicker addItemsWithTitles:@[@"明るい紙面",@"暗い紙面"]]; _themePicker.target=self; _themePicker.action=@selector(homeSettingsChanged:); [_home addSubview:_themePicker];
    [self homeLabel:_library.count ? @"本はオフラインで読めます。表示設定は次の起動にも引き継ぎます。" : @"本棚を読み込めません。アプリを再ビルドしてください。" size:12 frame:NSMakeRect(x, h-490, w-x-24, 30) parent:_home];
    _readingTitle=[self homeLabel:@"" size:17 frame:NSMakeRect(154,h-34,w-180,26) parent:root];
    _readingTitle.hidden=YES;
    _readingBar=[[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, 42)];
    [root addSubview:_readingBar positioned:NSWindowBelow relativeTo:_home];
    [self homeButton:@"前へ ←" action:@selector(previousPage:) frame:NSMakeRect(22, 6, 100, 28) parent:_readingBar];
    [self homeButton:@"次へ →" action:@selector(nextPage:) frame:NSMakeRect(130, 6, 100, 28) parent:_readingBar];
    _chapterPicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(246, 6, 340, 28)];
    _chapterPicker.target=self; _chapterPicker.action=@selector(selectChapter:); [_readingBar addSubview:_chapterPicker];
    [self homeButton:@"このページの例題 (e)" action:@selector(showExamples:) frame:NSMakeRect(600,6,190,28) parent:_readingBar];
    [self homeButton:@"出典・図版" action:@selector(showAttribution:) frame:NSMakeRect(w-228, 6, 206, 28) parent:_readingBar];
    _readingBar.wantsLayer=YES; _readingBar.layer.backgroundColor=[NSColor colorWithCalibratedWhite:0.96 alpha:1].CGColor;
    _readingBar.hidden=YES;
    [self installLearningBarIn:root];
    [self syncHomeSettings];
}
- (void)syncHomeSettings {
    _directionPicker.selectedSegment=_is_vertical ? 1 : 0;
    [_sizePicker selectItemWithTitle:[NSString stringWithFormat:@"文字 %u px",_font_size]];
    [_familyPicker selectItemAtIndex:_is_gothic ? 1 : 0]; [_themePicker selectItemAtIndex:_theme_id];
}
- (void)saveDisplayPreferences {
    NSUserDefaults *prefs=[NSUserDefaults standardUserDefaults];
    [prefs setObject:@{ @"size":@(_font_size), @"vertical":@(_is_vertical), @"gothic":@(_is_gothic), @"theme":@(_theme_id) } forKey:@"xy.home.display.v1"];
}
- (IBAction)homeSettingsChanged:(id)sender {
    (void)sender;
    _is_vertical=_directionPicker.selectedSegment == 1;
    _font_size=(uint8_t)[[_sizePicker.titleOfSelectedItem componentsSeparatedByString:@" "][1] intValue];
    _is_gothic=_familyPicker.indexOfSelectedItem == 1;
    _theme_id=(uint8_t)_themePicker.indexOfSelectedItem;
    eval_sexp_checked(_theme_id ? "(view/set! #:theme 'dark)" : "(view/set! #:theme 'light)");
    [self applyViewSettings];
}
- (IBAction)showHome:(id)sender {
    (void)sender;
    if (_learning) [self backToReading:nil];
    if (_editingSource) [self editSource:nil];
    [self syncHomeSettings];
    _selectAll=NO;
    _resumeReadingButton.enabled=_reading;
    _home.hidden=NO;
    [[self window] setTitle:@"xy — ホーム"];
}
- (IBAction)resumeReading:(id)sender {
    (void)sender; if (!_reading) return;
    _home.hidden=YES; _readingBar.hidden=NO; [self layoutReadingPage];
}
- (void)setReadingChrome:(BOOL)reading {
    NSArray *actions=@[NSStringFromSelector(@selector(editSource:)),NSStringFromSelector(@selector(applySource:)),NSStringFromSelector(@selector(runCommand:)),NSStringFromSelector(@selector(restoreSource:)),NSStringFromSelector(@selector(reloadSource:)),NSStringFromSelector(@selector(demoIvsOmni:)),NSStringFromSelector(@selector(demoIdsOmni:)),NSStringFromSelector(@selector(undoEdit:))];
    for (NSView *child in self.superview.subviews) if ([child isKindOfClass:[NSButton class]]) {
        NSButton *button=(NSButton *)child;
        if ([actions containsObject:NSStringFromSelector(button.action)]) button.hidden=reading;
    }
    _readingTitle.hidden=!reading;
    if (reading) _readingTitle.stringValue=[NSString stringWithFormat:@"%@    %@",_readingItem[@"title"],_readingItem[@"author"]];
}
- (void)leaveReader {
    if (_learning) [self backToReading:nil];
    if (!_reading) return;
    xy_host_reader_leave(); [self setReadingChrome:NO]; _reading=NO; _readingBar.hidden=YES;
    _readingItem=nil; _readingText=nil; _readingRuby=nil;
}
- (IBAction)resumeDocument:(id)sender {
    (void)sender;
    [self leaveReader];
    _selectAll=NO;
    _home.hidden=YES;
    [[self window] setTitle:_documentURL ? _documentURL.lastPathComponent : @"xy — 新しい文書"];
    [self workspaceNotice:_documentDirty ? @"編集中・未保存  ·  ⌘Sで保存" : @"文書  ·  ⌘Sで保存  ·  ⌘0でホーム" error:NO];
}
- (BOOL)saveDocumentToURL:(NSURL *)url {
    NSData *data=[self currentBuffer]; NSError *error=nil;
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        [self workspaceNotice:error.localizedDescription ?: @"保存できませんでした。" error:YES]; return NO;
    }
    _documentURL=url; _documentDirty=NO;
    [[self window] setTitle:url.lastPathComponent];
    [self workspaceNotice:@"文書を保存しました。" error:NO]; return YES;
}
- (BOOL)saveDocument {
    if (_reading || _editingSource) return NO;
    NSURL *url=_documentURL;
    if (!url) {
        NSSavePanel *panel=[NSSavePanel savePanel]; panel.nameFieldStringValue=@"Untitled.txt";
        if ([panel runModal] != NSModalResponseOK) return NO;
        url=panel.URL;
    }
    return [self saveDocumentToURL:url];
}
- (BOOL)confirmDocumentReplacement {
    if (!_documentDirty) return YES;
    NSAlert *a=[[NSAlert alloc] init]; a.messageText=@"編集中の文書を保存しますか？";
    a.informativeText=@"保存せずに進むと、現在の文書の変更は失われます。";
    [a addButtonWithTitle:@"保存"]; [a addButtonWithTitle:@"キャンセル"]; [a addButtonWithTitle:@"保存せずに進む"];
    NSModalResponse r=[a runModal];
    if (r==NSAlertSecondButtonReturn) return NO;
    if (r==NSAlertThirdButtonReturn) return YES;
    return [self saveDocument];
}
- (IBAction)newDocument:(id)sender {
    (void)sender;
    if (_editingSource) [self editSource:nil];
    [self leaveReader];
    if (![self confirmDocumentReplacement]) return;
    if (!xy_host_document_load((const uint8_t *)"",0)) { [self workspaceNotice:@"新しい文書を作れませんでした。" error:YES]; return; }
    _documentURL=nil; _documentDirty=NO;
    [self resumeDocument:nil];
}
- (IBAction)openDocument:(id)sender {
    (void)sender;
    NSOpenPanel *panel=[NSOpenPanel openPanel]; panel.canChooseDirectories=NO; panel.allowsMultipleSelection=NO;
    if ([panel runModal] != NSModalResponseOK) return;
    NSError *error=nil; NSData *data=[NSData dataWithContentsOfURL:panel.URL options:0 error:&error];
    if (!data || data.length>4096 || ![[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]) {
        [self workspaceNotice:@"編集できるのは4 KiBまでのUTF-8ファイルです。本は本棚から開いてください。" error:YES]; return;
    }
    if (_editingSource) [self editSource:nil];
    [self leaveReader];
    if (![self confirmDocumentReplacement]) return;
    if (!xy_host_document_load(data.bytes,(uint32_t)data.length)) { [self workspaceNotice:@"ファイルを開けませんでした。" error:YES]; return; }
    _documentURL=panel.URL; _documentDirty=NO;
    [self resumeDocument:nil];
}
- (IBAction)selectHomeBook:(id)sender {
    NSInteger index=[sender tag];
    if (index < 0 || (NSUInteger)index >= _library.count) return;
    if (_editingSource) [self editSource:nil];
    if (!_reading && !xy_host_reader_enter()) { [self workspaceNotice:@"読書画面を開けませんでした。" error:YES]; return; }
    _selectAll=NO;
    _reading=YES; _readingItem=_library[(NSUInteger)index];
    [self setReadingChrome:YES];
    _chapterIndex=0; _home.hidden=YES; _readingBar.hidden=NO;
    [_chapterPicker removeAllItems];
    for (NSDictionary *s in _readingItem[@"sections"]) [_chapterPicker addItemWithTitle:s[@"title"]];
    [self loadReadingChapter];
}
- (void)loadReadingChapter {
    NSDictionary *s=_readingItem[@"sections"][_chapterIndex];
    _readingText=[s[@"text"] dataUsingEncoding:NSUTF8StringEncoding]; _readingRuby=s[@"ruby"];
    _readingStart=0; _pageStarts=[NSMutableArray array];
    [_chapterPicker selectItemAtIndex:_chapterIndex]; [self layoutReadingPage];
}
- (BOOL)layoutReadingPage {
    if (!_reading || _readingStart >= _readingText.length) return NO;
    const uint8_t *all=_readingText.bytes;
    // Keep the candidate below the shared renderer's 1024-glyph host work area,
    // including ruby glyphs. The core does the final geometric fit.
    NSUInteger end=_readingStart, glyphs=0;
    while (end<_readingText.length && glyphs<900) {
        uint8_t first=all[end]; NSUInteger n=first<128 ? 1 : first<224 ? 2 : first<240 ? 3 : 4;
        end+=n; glyphs++;
    }
    NSUInteger rubyCount=0;
    for (NSDictionary *r in _readingRuby) {
        NSUInteger a=[r[@"start"] unsignedIntegerValue], b=[r[@"end"] unsignedIntegerValue];
        if (a>=_readingStart && a<end && ++rubyCount>64) end=a;
        if (a<end && b>end) end=a;
    }
    // Do not separate a variation selector / combining kana at a candidate edge.
    while (end<_readingText.length) {
        uint32_t cp=decode_first_utf8_cp(all+end,(uint32_t)(_readingText.length-end));
        if (!(cp==0x3099 || cp==0x309a || (cp>=0xfe00 && cp<=0xfe0f) || (cp>=0xe0100 && cp<=0xe01ef))) break;
        end+=cp>0xffff ? 4 : 3;
    }
    if (end<=_readingStart) return NO;
    NSMutableData *readings=[NSMutableData data], *spans=[NSMutableData data];
    for (NSDictionary *r in _readingRuby) {
        NSUInteger a=[r[@"start"] unsignedIntegerValue], b=[r[@"end"] unsignedIntegerValue];
        if (a<_readingStart || b>end) continue;
        NSData *bytes=[r[@"text"] dataUsingEncoding:NSUTF8StringEncoding];
        XyReaderRuby span={(uint32_t)(a-_readingStart),(uint32_t)(b-_readingStart),(uint32_t)readings.length,(uint32_t)(readings.length+bytes.length)};
        [spans appendBytes:&span length:sizeof(span)]; [readings appendData:bytes];
    }
    (void)xy_host_reader_context([_readingItem[@"id"] isEqualToString:@"sicp"] ? 2 : 0,(uint32_t)_chapterIndex,(uint32_t)_readingStart);
    int32_t consumed=xy_host_reader_load(all+_readingStart,(uint32_t)(end-_readingStart),readings.bytes ?: (const void *)"",(uint32_t)readings.length,spans.bytes ?: (const void *)"",(uint32_t)(spans.length/sizeof(XyReaderRuby)));
    if (consumed<=0) { [self workspaceNotice:@"このページを組版できません。文字サイズを小さくしてください。" error:YES]; return NO; }
    _readingEnd=_readingStart+(NSUInteger)consumed;
    NSDictionary *chapter=_readingItem[@"sections"][_chapterIndex];
    _workspaceMessage=[NSString stringWithFormat:@"%@ · %@ · %lu%%",_readingItem[@"title"],chapter[@"title"],(unsigned long)(100*_readingStart/MAX((NSUInteger)1,_readingText.length))];
    [[self window] setTitle:[NSString stringWithFormat:@"xy — %@ / %@",_readingItem[@"title"],chapter[@"title"]]];
    [self setNeedsDisplay:YES]; [[self window] makeFirstResponder:self]; return YES;
}
- (IBAction)selectChapter:(id)sender {
    (void)sender; if (!_reading) return;
    _chapterIndex=_chapterPicker.indexOfSelectedItem; [self loadReadingChapter];
}
- (IBAction)nextPage:(id)sender {
    (void)sender; if (!_reading) return;
    if (_readingEnd<_readingText.length) {
        NSUInteger old=_readingStart; _readingStart=_readingEnd;
        if ([self layoutReadingPage]) [_pageStarts addObject:@(old)]; else _readingStart=old;
    } else if (_chapterIndex+1 < (NSInteger)[_readingItem[@"sections"] count]) {
        _chapterIndex++; [self loadReadingChapter];
    }
}
- (IBAction)previousPage:(id)sender {
    (void)sender; if (!_reading) return;
    if (_pageStarts.count) {
        _readingStart=[_pageStarts.lastObject unsignedIntegerValue]; [_pageStarts removeLastObject]; [self layoutReadingPage];
    } else if (_chapterIndex>0) {
        _chapterIndex--; [self loadReadingChapter];
        while (_readingEnd<_readingText.length) {
            NSUInteger old=_readingStart; _readingStart=_readingEnd;
            if (![self layoutReadingPage]) { _readingStart=old; break; }
            [_pageStarts addObject:@(old)];
        }
    }
}
- (IBAction)showAttribution:(id)sender {
    (void)sender; if (!_reading) return;
    NSAlert *a=[[NSAlert alloc] init]; a.messageText=_readingItem[@"title"];
    a.informativeText=[NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@",_readingItem[@"author"],_readingItem[@"detail"],_readingItem[@"license"],_readingItem[@"source"]];
    NSArray *figures=_readingItem[@"sections"][_chapterIndex][@"figures"];
    [a addButtonWithTitle:@"閉じる"];
    if (figures.count) [a addButtonWithTitle:@"この章の図版を見る"];
    if ([a runModal]==NSAlertSecondButtonReturn && figures.count) [self showReadingFigures];
}
- (void)showReadingFigures {
    NSArray *figures=_readingItem[@"sections"][_chapterIndex][@"figures"];
    NSString *directory=[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"figures"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:directory])
        directory=[[[NSProcessInfo processInfo].arguments[0] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"figures"];
    NSMutableString *html=[NSMutableString stringWithString:@"<!doctype html><meta charset='utf-8'><style>body{margin:24px;background:#faf6ee;color:#222;font:16px sans-serif}svg{max-width:100%;height:auto;margin:0 0 40px}figure{margin:0}</style>"];
    for (NSDictionary *figure in figures) {
        NSString *file=[figure[@"file"] lastPathComponent];
        NSString *svg=[NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:file] encoding:NSUTF8StringEncoding error:NULL];
        if (svg) [html appendFormat:@"<figure>%@</figure>",svg];
    }
    WKWebViewConfiguration *config=[[WKWebViewConfiguration alloc] init];
    config.defaultWebpagePreferences.allowsContentJavaScript=NO;
    WKWebView *web=[[WKWebView alloc] initWithFrame:NSMakeRect(0,0,780,450) configuration:config];
    [web loadHTMLString:html baseURL:nil];
    NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=@"この章の図版";
    alert.accessoryView=web; [alert addButtonWithTitle:@"閉じる"]; [alert runModal];
}
