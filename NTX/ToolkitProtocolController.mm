/*
	File:		ToolkitProtocolController.mm

	Contains:	Toolkit Protocol controller interface.
					The controller knows about the toolkit protocol.
					It translates requests for Newton data to toolkit dock commands
					that it passes to the active session.

	The frontmost window (containing an inspector view) binds to the global instance of the ProtocolController.
	The ProtocolController listens for a connection.
	Once a connection is established, the ProtocolController remains bound to the window.
	Prior to that, the ProtocolController binds to the frontmost window as that changes.

	This controller interacts with the UI like so:
	ProtocolController		WindowController
	----							----
	detect dis|connection?
	send notification of change in connection status
								->	if disconnected then we do not own the nub
									else if we are frontmost then request ownership of the nub (self)
								<-
	if connected and no txn in progress then
		delegate = requester
		send notification of change of nub ownership
								->	if we are the requester then we own the nub (else we don’t)

									if we become frontmost then request ownership of the nub (self)

									connection status icon | disconnect button is bound to nub!=nil

	delegate (NTXWindowController) responds to NTXNubFeedback protocol to:
		report text|progress feedback		@property(readonly) NSProgress * progress;
		report inspector text				- (void)receivedText:(NSString *)inText;
		report screenshot received			- (void)receivedObject:(RefArg)inObject;	interpretation = 'screenshot or 'dante


	Hierarchy:	toolkit
					 stream
					  endpointController
						endpoint

	Written by:	Newton Research, 2012.
*/
#define kDebugOn 0

#import "ToolkitProtocolController.h"
#import "NTKProtocol.h"
#import "DockErrors.h"
#import "PreferenceKeys.h"


extern NewtonErr	GetPackageDetails(NSURL * inURL, NSString ** outName, unsigned int * outSize);
extern "C" const char *	GetFramesErrorString(int inErr);
extern void			PrintFramesErrorMsg(const char * inStr, RefArg inData);


/* -----------------------------------------------------------------------------
	N T X S t r e a m
----------------------------------------------------------------------------- */
@interface NTXStream ()
{
	dispatch_semaphore_t readDataReady;
	dispatch_queue_t accessQueue;
	NSMutableData * inputStreamBuf;
	NCEndpointController * ep;
}
@end


@implementation NTXStream

- (id)init {
	if (self = [super init]) {
		accessQueue = dispatch_queue_create("com.newton.connection.istream", NULL);
		inputStreamBuf = [[NSMutableData alloc] init];
		ep = [[NCEndpointController alloc] init];
	}
	return self;
}


- (void)observeValueForKeyPath:(NSString *)inKeyPath
							 ofObject:(id)inObject
								change:(NSDictionary *)inChange
							  context:(void *)inContext {
//	NSNumber * err = inChange[NSKeyValueChangeNewKey];	//doesn’t really matter what the error is, we just want to signal data-ready to stop the wait-loop
	[self addData:nil];
}


/*------------------------------------------------------------------------------
	Open the queue -- start listening.
	Args:		--
	Return:	--
------------------------------------------------------------------------------*/

- (void)open {
	readDataReady = dispatch_semaphore_create(0);
	[ep startListening:self];	// call us back <NTXStreamProtocol> when data arrives
	[ep addObserver:self forKeyPath:@"error" options:NSKeyValueObservingOptionNew context:nil];
}


/*------------------------------------------------------------------------------
	Close the queue -- flush events and stop listening for more.
	Args:		--
	Return:	--
------------------------------------------------------------------------------*/

- (void)close {
	if (ep.isActive) {
		[ep stop];		// will set ep.error
//		ep.error = kDockErrAccessDenied;
		[ep removeObserver:self forKeyPath:@"error"];
	}
}


/*------------------------------------------------------------------------------
	Dispose the queue.
	Args:		--
	Return:	--
------------------------------------------------------------------------------*/

- (void)dealloc {
	[self close];
	readDataReady = nil;
	ep = nil;
	accessQueue = nil;
}


/* -----------------------------------------------------------------------------
	NTXStreamProtocol
----------------------------------------------------------------------------- */

- (void)addData:(NSData *)inData {
	if (inData) {
		// add chunk of data to the input stream
		// serialise access via a queue
		dispatch_sync(accessQueue, ^{
			[inputStreamBuf appendData:inData];
		});
	}
	dispatch_semaphore_signal(readDataReady);
}


- (NewtonErr)read:(char *)inBuf length:(NSUInteger)inLength {
	// read chunk of data from the input stream
	// serialise access via a queue
	NewtonErr err = noErr;
	__block NSUInteger reqLength = inLength;
	__block NSUInteger index = 0;

	dispatch_sync(accessQueue, ^{
		NSUInteger count = inputStreamBuf.length;
		if (count > 0) {
			if (count > reqLength)
				count = reqLength;
			[inputStreamBuf getBytes:inBuf+index length:count];
			[inputStreamBuf replaceBytesInRange:NSMakeRange(0, count) withBytes:NULL length:0];
			index += count;
			reqLength -= count;
		}
	});

	while (reqLength > 0) {
		XFAIL(err = ep.error)
		XFAILIF(dispatch_semaphore_wait(readDataReady, DISPATCH_TIME_FOREVER), err = kDockErrIdleTooLong;)	// non-zero result => timeout
//NSLog(@"-[NTXStream read:length:%ld]",reqLength);

		dispatch_sync(accessQueue, ^{
			NSUInteger count = inputStreamBuf.length;
			if (count > reqLength)
				count = reqLength;
			[inputStreamBuf getBytes:inBuf+index length:count];
			[inputStreamBuf replaceBytesInRange:NSMakeRange(0, count) withBytes:NULL length:0];
			index += count;
			reqLength -= count;
		});
	}
	return err;
}


- (NewtonErr)send:(char *)inBuf length:(NSUInteger)inLength {
	return [ep.endpoint write:inBuf length:inLength];
}

@end


/* -----------------------------------------------------------------------------
	N o t i f i c a t i o n s
----------------------------------------------------------------------------- */

NSString * const kNubStatusDidChangeNotification = @"NTX:NubStatus";
NSString * const kNubOwnerDidChangeNotification = @"NTX:NubOwner";


#pragma mark -
/* -----------------------------------------------------------------------------
	N T X T o o l k i t P r o t o c o l C o n t r o l l e r
----------------------------------------------------------------------------- */
@interface NTXToolkitProtocolController ()
{
//	event queue
	NTXStream * ioStream;

	NewtonErr toolkitError;
	RefStruct toolkitObject;
	NSString * toolkitMessage;

	NewtonErr exceptionError;
	RefStruct exceptionObject;
	NSString * exceptionMessage;

//	package installation
	unsigned int totalAmount, amountDone;
}
// feedback to UI
@property(strong) id<NTXNubFeedback> delegate;
@end

// There is one global NTXToolkitProtocolController
NTXToolkitProtocolController * gNTXNub = nil;

@implementation NTXToolkitProtocolController

/* -----------------------------------------------------------------------------
	Class management of the singleton dock instance.
----------------------------------------------------------------------------- */

+ (BOOL)isAvailable {
	return gNTXNub.delegate == nil;
}


+ (NTXToolkitProtocolController *)bind:(id<NTXNubFeedback>)inDelegate {
	if (gNTXNub == nil) {
		gNTXNub = [[NTXToolkitProtocolController alloc] init];
	}
	if (self.isAvailable) {
		gNTXNub.delegate = inDelegate;
		if (!gNTXNub.isTethered) {
			[gNTXNub open];
		}
		return gNTXNub;
	}
	return nil;
}


+ (void)unbind:(id<NTXNubFeedback>)inDelegate {
	NSAssert(gNTXNub != nil, @"gNTXNub is nil");
	if (self.isAvailable) {
		// we’re not bound
		return;
	}
	if (gNTXNub.delegate == inDelegate) {
		[gNTXNub close];
		gNTXNub.delegate = nil;
	}
}


#pragma mark Initialization
/* -----------------------------------------------------------------------------
	Initialize a new instance.
----------------------------------------------------------------------------- */

- (id)init {
	if (self = [super init]) {
		self.delegate = nil;
		ioStream = [[NTXStream alloc] init];
	}
	return self;
}


- (void)open {
	_isTethered = NO;
	self.breakLoopDepth = 0;
	[ioStream open];
	[self waitForEvent];
}


- (void)close {
	_isTethered = NO;
	[ioStream close];
}


- (void)dealloc {
	[self close];
}


/*------------------------------------------------------------------------------
	Respond to serial port change notification.
	We need to reset the connection to listen on the new serial port.
	Args:		inNotification
	Return:	--
------------------------------------------------------------------------------*/

// start listening for notifications re: serial port changes
//	[[NSNotificationCenter defaultCenter] addObserver:self
//														  selector:@selector(serialPortChanged:)
//																name:kSerialPortChanged
//															 object:nil];

- (void)serialPortChanged:(NSNotification *)inNotification {
	/* huh? */;
}


/* -----------------------------------------------------------------------------
	Read word from Newton.
----------------------------------------------------------------------------- */

- (NewtonErr)readWord:(int *)outWord {
	NewtonErr err = noErr;
	union
	{
		char chars[4];
		ULong word;
	} buf;

	err = [ioStream read:buf.chars length:sizeof(buf)];
	*outWord = CANONICAL_LONG(buf.word);
if (err) NSLog(@"-[NTXToolkitProtocolController readWord:] error = %d",err);
	return err;
}


/* -----------------------------------------------------------------------------
	Read command header words from Newton.
----------------------------------------------------------------------------- */

- (NewtonErr)readHeader1:(ULong *)outHdr1 header2:(ULong *)outHdr2 {
	NewtonErr err = noErr;
	union
	{
		char chars[8];
		struct
		{
			ULong hdr1;
			ULong hdr2;
		} words;
	} buf;

	// NTXStream* ioStream should return error on disconnection
	// no need for dock event queue any more
	// just read from input stream

	err = [ioStream read:buf.chars length:sizeof(buf)];
	*outHdr1 = CANONICAL_LONG(buf.words.hdr1);
	*outHdr2 = CANONICAL_LONG(buf.words.hdr2);
#if kDebugOn
if (err) {
	NSLog(@"-[NTXToolkitProtocolController readHeader1:header2:] error = %d",err);
}
#endif
	return err;
}


/* -----------------------------------------------------------------------------
	Read command header from Newton.
----------------------------------------------------------------------------- */

- (NewtonErr)readCommand:(EventType *)outCmd length:(NSUInteger *)outLength {
	NewtonErr	err = noErr;
	ULong		hdr1;
	ULong		hdr2;

	*outCmd = 0;
	*outLength = 0;

	XTRY
	{
		XFAIL(err = [self readHeader1:&hdr1 header2:&hdr2])
		XFAILNOT(hdr1 == kNewtEventClass && hdr2 == kToolkitEventId, err = kDockErrBadHeader;)
		XFAIL(err = [self readHeader1:&hdr1 header2:&hdr2])

		*outCmd = hdr1;
		*outLength = hdr2;

#if kDebugOn
printf("\n     <-- %c%c%c%c ", (*outCmd >> 24) & 0xFF, (*outCmd >> 16) & 0xFF, (*outCmd >> 8) & 0xFF, *outCmd & 0xFF);
if (*outLength > 0) printf("[%ld] ", *(unsigned long *)outLength);
#endif
	}
	XENDTRY;
if (err) NSLog(@"-[NTXToolkitProtocolController readCommand:length:] error = %d",err);
	return err;
}


- (Ref)readRef:(NSUInteger)inLength {
	NewtonErr err = noErr;
	char * buf = NULL;
	RefVar rref;

	XTRY
	{
		buf = (char *)malloc(inLength);
		XFAILNOT(buf, err = kOSErrNoMemory;)
		err = [ioStream read:buf length:inLength];

		CPtrPipe pipe;
		pipe.init(buf, inLength, NO, nil);
		rref = UnflattenRef(pipe);
	}
	XENDTRY;
	if (buf)
		free(buf);

	return rref;
}


/* -----------------------------------------------------------------------------
	Send command header words to Newton.
----------------------------------------------------------------------------- */

- (NewtonErr)sendHeader1:(ULong)inHdr1 header2:(ULong)inHdr2 {
	NewtonErr err = noErr;
	union
	{
		char chars[8];
		struct
		{
			ULong hdr1;
			ULong hdr2;
		} words;
	} buf;

	buf.words.hdr1 = CANONICAL_LONG(inHdr1);
	buf.words.hdr2 = CANONICAL_LONG(inHdr2);
	err = [ioStream send:buf.chars length:sizeof(buf)];
	
	return err;
}


/* -----------------------------------------------------------------------------
	Send command header to Newton.
----------------------------------------------------------------------------- */

- (NewtonErr)sendCommand:(EventType)inCmd length:(NSUInteger)inLength {
	NewtonErr	err = noErr;
	XTRY
	{
#if kDebugOn
printf("\n%c%c%c%c --> ", (inCmd >> 24) & 0xFF, (inCmd >> 16) & 0xFF, (inCmd >> 8) & 0xFF, inCmd & 0xFF);
if (inLength > 0) printf("[%ld] ", (unsigned long)inLength);
#endif

		XFAIL(err = [self sendHeader1:kNewtEventClass header2:kToolkitEventId])
		err = [self sendHeader1:inCmd header2:inLength];
	}
	XENDTRY;
	return err;
}


/* -----------------------------------------------------------------------------
	Send simple command to Newton.
----------------------------------------------------------------------------- */

- (NewtonErr)sendCommand:(EventType)inCmd {
	return [self sendCommand:inCmd length:0];
}


/* -----------------------------------------------------------------------------
	Send command with data to Newton.
----------------------------------------------------------------------------- */

- (NewtonErr)sendCommand:(EventType)inCmd data:(char *)inData length:(NSUInteger)inLength {
	NewtonErr	err = noErr;
	XTRY
	{
		XFAIL(err = [self sendCommand:inCmd length:inLength])
		XFAIL(err = [ioStream send:inData length:inLength])

		NSUInteger padLength = inLength & 0x03;
		if (padLength != 0)
		{
		// pad with zeroes
			ULong padding = 0;
			err = [ioStream send: (char *)&padding length: 4 - padLength];
		}
	}
	XENDTRY;
	return err;
}


/* -----------------------------------------------------------------------------
	Send command with data to Newton.
----------------------------------------------------------------------------- */

- (NewtonErr)sendCommand:(EventType)inCmd value:(int)inValue {
	ULong value = CANONICAL_LONG(inValue);
	return [self sendCommand:inCmd data:(char *)&value length:sizeof(ULong)];
}


/*------------------------------------------------------------------------------
	Dispatch a block to the async queue.
	This waits for a toolkit event to arrive then despatches it to its
	event handler.
	Args:		inEvent
	Return:	--
------------------------------------------------------------------------------*/

- (void)waitForEvent {
	__block NTXToolkitProtocolController *__weak weakself = self;	// use weak reference so async block does not retain self
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		[weakself doDockEventLoop];
		// if we get here then the event queue has been flushed, so we can ditch it: there are no more events coming

		dispatch_async(dispatch_get_main_queue(), ^{
			[NSNotificationCenter.defaultCenter postNotificationName:kNubStatusDidChangeNotification object:weakself.delegate userInfo:@{@"error":[NSNumber numberWithInt:kDockErrDisconnected]}];
		});
	});
}

- (void)doDockEventLoop {
	NewtonErr	err;
	char			exStr[256];
	EventType	evtCmd;
	NSUInteger	evtLen;
	while ((err = [self readCommand:&evtCmd length:&evtLen]) == noErr) {
		switch (evtCmd) {
		case kTConnect: {
		// - data
			// send kTOK
			err = [self sendCommand:kTOK];
			if (err == noErr) {
				_isTethered = YES;
				self.delegate.connected = YES;
			}
		}
		break;

		case kTText: {
		// + C string
			while (evtLen > 0) {
				NSUInteger strLen = MIN(evtLen, 255);
				err = [ioStream read:exStr length:strLen];
				exStr[strLen] = 0;
				NSString * str = [NSString stringWithCString:exStr encoding:NSMacOSRomanStringEncoding];
				dispatch_async(dispatch_get_main_queue(), ^{[self.delegate receivedText:str];});
				evtLen -= strLen;
			}
		}
		break;

//			case 'fstk': ?? mentioned in Jake Borden’s NewtonInspector
		case kTObject: {
		// + ref
			toolkitObject = [self readRef:evtLen];
			RefVar interp(GetFrameSlot(toolkitObject, MakeSymbol("interpretation")));
			RefVar data(GetFrameSlot(toolkitObject, MakeSymbol("data")));
			if (SymbolCompareLex(interp, MakeSymbol("screenshot")) == 0) {
				dispatch_async(dispatch_get_main_queue(), ^{[self.delegate receivedScreenshot:data];});
			} else if (SymbolCompareLex(interp, MakeSymbol("dante")) == 0) {
				dispatch_async(dispatch_get_main_queue(), ^{[self.delegate receivedObject:data];});
			}
		}
		break;

		case kTResult: {
		// + word = error code
			err = [self readWord:&toolkitError];
			if (toolkitError) {
				NSString * str = [NSString stringWithFormat:@"\n\t%d\n", toolkitError];
				dispatch_async(dispatch_get_main_queue(), ^{[self.delegate receivedText:str];});
			}
		}
		break;

		case kTCode: {
		// + ref length
		// + ref
			// discard the evtLen -- it’s totally erroneous, just an echo of the kTCode evtLen sent
			ULong resultLen;
			err = [self readWord:(int *)&resultLen];
			toolkitObject = [self readRef:resultLen];
			dispatch_async(dispatch_get_main_queue(), ^{[self.delegate receivedObject:toolkitObject];});
		}
		break;

		case kTEOM: {
		// - data
		}
		break;

		case kTEnterBreakLoop: {
		// - data
			++self.breakLoopDepth;
			NSString * str = [NSString stringWithFormat:@"\nEntering break loop, depth = %u\n", (unsigned int)self.breakLoopDepth];
			dispatch_async(dispatch_get_main_queue(), ^{[self.delegate receivedText:str];});
		}
		break;

		case kTExitBreakLoop: {
		// - data
			if (self.breakLoopDepth > 0) {
				NSString * str = [NSString stringWithFormat:@"\nExiting break loop, depth = %u\n", (unsigned int)self.breakLoopDepth];
				dispatch_async(dispatch_get_main_queue(), ^{[self.delegate receivedText:str];});
				--self.breakLoopDepth;
			}
			else
				NSLog(@"NTXToolkitProtocolController.breakLoopDepth underflow");
		}
		break;

		case kTDownload: {
		// - data
			// initiates package d/l sub-protocol
		}
		break;

		case kTExceptionError: {
		// + word = exception name length
		// + char[] = exception name (nul-terminated)
		// + word = error code

		// NTK reports this like:
		// <tab> Undefined global function: DefConst
		// <tab> evt.ex.fr.intrp;type.ref.frame
		// <tab> -48808

			NewtonErr exErr;
			ULong exItemLen;
			err = [self readWord:(int *)&exItemLen];
			err = [ioStream read:exStr length:exItemLen];
			err = [self readWord:(int *)&exErr];

			const char * errStr;
			if ((errStr = GetFramesErrorString(exErr)) != NULL) {
				printf("\n\t");
				PrintFramesErrorMsg(errStr, AllocateFrame());
			}
printf("\n\t%s\n\t%d\n", exStr, exErr);
//				NSString * str = [NSString stringWithFormat:@"\n\t%s\n\t%d\n", exStr, exErr];
//				dispatch_async(dispatch_get_main_queue(), ^{[self.delegate receivedText:str];});
		}
		break;

		case kTExceptionMessage: {
		// + word = exception name length
		// + char[] = exception name (nul-terminated)
		// + word = message length
		// + char[] = message (nul-terminated)

			ULong exItemLen;
			err = [self readWord:(int *)&exItemLen];
			err = [ioStream read:exStr length:exItemLen];
			printf("\n\t%s\n\t",exStr);

			err = [self readWord:(int *)&exItemLen];
			while (exItemLen > 0) {
				NSUInteger strLen = MIN(exItemLen, 255);
				err = [ioStream read:exStr length:strLen];
				exStr[strLen] = 0;
				printf("%s",exStr);
				exItemLen -= strLen;
			}
			printf("\n");
		}
		break;

		case kTExceptionRef: {
// Jake Borden says:
// + word = exception name length
// + char[] = exception name (nul-terminated)
// + word = ref length
		// + ref = exception frame
			const char * str;
			toolkitObject = [self readRef:evtLen];
PrintObject(toolkitObject, 0);
printf("\n");

			RefVar exErr(GetFrameSlot(toolkitObject, SYMA(errorCode)));
			if (ISINT(exErr) && (str = GetFramesErrorString(RINT(exErr))) != NULL) {
				printf("\n\t");
				PrintFramesErrorMsg(str, toolkitObject);
				printf("\n");
			}
		}
		break;

		case kTTerminate: {
		// - data
			_isTethered = NO;
			self.delegate.connected = NO;
			// that’s the end of THIS session
			// but keep listening for the NEXT session
			err = kDockErrDisconnected;
		}
		break;

		default:
			NSLog(@"NTXToolkitProtocolController does not handle command '%c%c%c%c'", (evtCmd >> 24) & 0xFF, (evtCmd >> 16) & 0xFF, (evtCmd >> 8) & 0xFF, evtCmd & 0xFF);
			break;
		}
	}
}


#pragma mark Public Interface
/* -----------------------------------------------------------------------------
	Send NewtonScript for execution on the tethered Newton device.
	Args:		inScript
	Return:	--
----------------------------------------------------------------------------- */
extern "C" Ref	FCompile(RefArg inRcvr, RefArg inStr);
extern void REPExceptionNotify(Exception * inException);

- (void)evaluate:(NSString *)inScript {
	if (!self.isTethered) {
		[self.delegate receivedText:@"Not connected to Newton.\n"];
		return;
	}

	NSUInteger strLen = [inScript length];
	UniChar * str = (UniChar *)malloc((strLen+1) * sizeof(UniChar));
	[inScript getCharacters:str range:NSMakeRange(0, strLen)];
	str[strLen] = 0;

	char * codeBlockData = NULL;

	newton_try
	{
		// compile codeblock
		RefVar codeBlock(FCompile(RA(NILREF), MakeString(str)));
		free(str), str = NULL;

		// prepare data
		NSUInteger objLength = FlattenRefSize(codeBlock);
		// kTCode requires ULong (unused by Newton -- of unknown purpose) before the codeBlock NSOF
		NSUInteger dataLength = sizeof(ULong) + objLength;
		codeBlockData = (char *)malloc(dataLength);
		memset(codeBlockData, 0, sizeof(ULong));

		CPtrPipe pipe;
		pipe.init(codeBlockData + sizeof(ULong), objLength, NO, nil);
		FlattenRef(codeBlock, pipe);

		[self sendCommand:kTCode data:codeBlockData length:dataLength];
	}
	newton_catch_all
	{
		REPExceptionNotify(CurrentException());
	}
	end_try;
	if (str)
		free(str);
	if (codeBlockData)
		free(codeBlockData);
}


/* -----------------------------------------------------------------------------
	Install a Newton package onto the tethered Newton device.
----------------------------------------------------------------------------- */

- (void)installPackage:(NSURL *)inPackage {
// build NSData of word:length data:pkg
//	[self sendCommand:kTLoadPackage data:codeBlockData length:dataLength];
// how are we going to provide feedback?!
}


/* -----------------------------------------------------------------------------
	Take a screenshot of the tethered Newton device.
----------------------------------------------------------------------------- */

- (void)takeScreenshot {
	[self evaluate:@"|ScreenShot:NTK|()"];
// async -- wait for the kTObject response w/ { interpretation:'screenshot, data:{screenInfo} }
}


/* -----------------------------------------------------------------------------
	Disconnect from the tethered Newton device.
----------------------------------------------------------------------------- */

- (void)disconnect {
	[self sendCommand:kTTerminate data:NULL length:0];
	// if no response in 3 secs, clean up anyway
}

@end