/*
	File:		InspectorViewController.h

	Abstract:	The InspectorViewController accepts text for NewtonScript evaluation,
					prints results and loads/saves inspector view content.

	Written by:		Newton Research, 2015.
*/

#import <AppKit/AppKit.h>


/* -----------------------------------------------------------------------------
	N T X I n s p e c t o r S p l i t V i e w C o n t r o l l e r
	The divider in the content split view shows TellUser() text.
----------------------------------------------------------------------------- */
@interface NTXInspectorSplitViewController : NSSplitViewController
{
	IBOutlet NSSplitViewItem * inspectorItem;
}
@property NSString * tellUserText;
- (IBAction)toggleInspector:sender;
@end

@interface NTXSplitView : NSSplitView
@end


/* -----------------------------------------------------------------------------
	I n s p e c t o r V i e w C o n t r o l l e r
	Controller for the inspector view.
----------------------------------------------------------------------------- */
@class NTXEditorView, NTXOutputRedirect;

@interface NTXInspectorViewController : NSViewController
{
	IBOutlet NTXEditorView * inspectorView;
}
@property(readonly) NSURL * inspectorTextURL;

@end

