// Included inside XyCanvasView. The shared Zig owner holds every draft and VM.
- (void)installLearningBarIn:(NSView *)root {
    _learningBar=[[NSView alloc] initWithFrame:NSMakeRect(0,0,NSWidth(root.bounds),42)];
    _learningBar.wantsLayer=YES;
    _learningBar.layer.backgroundColor=[NSColor colorWithCalibratedWhite:0.96 alpha:1].CGColor;
    NSArray *titles=@[@"本文へ戻る (Esc)",@"実行 (⌘R)",@"環境をリセット",@"原文のコード",@"コード / メモ"];
    NSArray *selectors=@[NSStringFromSelector(@selector(backToReading:)),NSStringFromSelector(@selector(runLearning:)),NSStringFromSelector(@selector(resetLearning:)),NSStringFromSelector(@selector(restoreLearning:)),NSStringFromSelector(@selector(toggleLearningNotes:))];
    for (NSUInteger i=0;i<titles.count;i++)
        [self homeButton:titles[i] action:NSSelectorFromString(selectors[i]) frame:NSMakeRect(20+i*192,6,180,28) parent:_learningBar];
    [root addSubview:_learningBar positioned:NSWindowAbove relativeTo:_readingBar];
    _learningBar.hidden=YES;
}
- (IBAction)showExamples:(id)sender {
    (void)sender;
    if (!_reading || _learning || ![_readingItem[@"id"] isEqualToString:@"sicp"] || !_learningData) {
        [self workspaceNotice:@"SICPの本文で例題を開けます。" error:NO]; return;
    }
    int32_t count=xy_host_learning_page((uint32_t)_chapterIndex,(uint32_t)_readingStart,(uint32_t)_readingEnd);
    NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=@"このページの例題";
    if (count<=0) { alert.informativeText=@"このページには実行用のコードがありません。本文を先へ進めてください。"; [alert runModal]; return; }
    NSPopUpButton *picker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,560,30)];
    for (int32_t i=0;i<count;i++) {
        uint8_t out[4096]; int32_t n=xy_host_learning_choice((uint32_t)i,out,sizeof(out));
        NSString *code=n>=0 ? [[NSString alloc] initWithBytes:out length:(NSUInteger)n encoding:NSUTF8StringEncoding] : @"Unavailable";
        [picker addItemWithTitle:[[code componentsSeparatedByString:@"\n"] firstObject]];
    }
    alert.informativeText=@"コードを編集して試します。作業とメモはRAM上に保持されます。";
    alert.accessoryView=picker; [alert addButtonWithTitle:@"開く"]; [alert addButtonWithTitle:@"本文に戻る"];
    if ([alert runModal]==NSAlertFirstButtonReturn) (void)[self openLearningOrdinal:(uint32_t)picker.indexOfSelectedItem];
}
- (BOOL)openLearningOrdinal:(uint32_t)ordinal {
    if (!xy_host_learning_open(ordinal)) return NO;
    _learning=YES; _selectAll=NO;
    _readingBar.hidden=YES; _learningBar.hidden=NO;
    _readingTitle.stringValue=@"SICP — 編集して試す / RAM";
    [self setNeedsDisplay:YES]; [[self window] makeFirstResponder:self];
    return YES;
}
- (IBAction)backToReading:(id)sender {
    (void)sender;
    if (!_learning) return;
    xy_host_learning_leave(); _learning=NO; _selectAll=NO;
    _learningBar.hidden=YES; _readingBar.hidden=NO;
    [self setReadingChrome:YES]; [self layoutReadingPage];
}
- (IBAction)runLearning:(id)sender {
    (void)sender; if (!_learning) return;
    (void)xy_host_learning_action(0); [self setNeedsDisplay:YES];
}
- (IBAction)resetLearning:(id)sender {
    (void)sender; if (!_learning) return;
    (void)xy_host_learning_action(1); [self setNeedsDisplay:YES];
}
- (IBAction)restoreLearning:(id)sender {
    (void)sender; if (!_learning) return;
    (void)xy_host_learning_action(2); [self setNeedsDisplay:YES];
}
- (IBAction)toggleLearningNotes:(id)sender {
    (void)sender; if (!_learning) return;
    _selectAll=NO; (void)xy_host_learning_action(3); [self setNeedsDisplay:YES];
}
