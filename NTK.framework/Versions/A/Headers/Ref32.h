
/*------------------------------------------------------------------------------
	Legacy Refs for a 64-bit world.
	See also Newton/ObjectSystem.cc which does this for Refs createwd by NTK.
------------------------------------------------------------------------------*/
#if !defined(__REF32_H)
#define __REF32_H 1

typedef int32_t Ref32;

#define OBJHEADER32 \
	uint32_t size  : 24; \
	uint32_t flags :  8; \
	union { \
		struct { \
			uint32_t	locks :  8; \
			uint32_t	slots : 24; \
		} count; \
		int32_t stuff; \
		Ref32 destRef; \
	}gc;

struct ObjHeader32
{
	OBJHEADER32
}__attribute__((packed));

struct BinaryObject32
{
	OBJHEADER32
	Ref32		objClass;
	char		data[];
}__attribute__((packed));

struct ArrayObject32
{
	OBJHEADER32
	Ref32		objClass;
	Ref32		slot[];
}__attribute__((packed));

struct FrameObject32
{
	OBJHEADER32
	Ref32		map;
	Ref32		slot[];
}__attribute__((packed));

struct FrameMapObject32
{
	OBJHEADER32
	Ref32		objClass;
	Ref32		supermap;
	Ref32		slot[];
}__attribute__((packed));

struct SymbolObject32
{
	OBJHEADER32
	Ref32		objClass;
	ULong		hash;
	char		name[];
}__attribute__((packed));

struct StringObject32
{
	OBJHEADER32
	Ref32		objClass;
	UniChar	str[];
}__attribute__((packed));


#define BYTE_SWAP_SIZE(n) (((n << 16) & 0x00FF0000) | (n & 0x0000FF00) | ((n >> 16) & 0x000000FF))
#if defined(hasByteSwapping)
#define CANONICAL_SIZE BYTE_SWAP_SIZE
#else
#define CANONICAL_SIZE(n) (n)
#endif

#define SIZEOF_BINARY32OBJECT (sizeof(ObjHeader32) + sizeof(Ref32))
#define SIZEOF_ARRAY32OBJECT (sizeof(ObjHeader32) + sizeof(Ref32))
#define SIZEOF_FRAMEMAP32OBJECT (sizeof(ObjHeader32) + sizeof(Ref32) + sizeof(Ref32))

#define ARRAY32LENGTH(_o) (ArrayIndex)((CANONICAL_SIZE(_o->size) - SIZEOF_ARRAY32OBJECT) / sizeof(Ref32))
#define BINARY32LENGTH(_o) (size_t)(CANONICAL_SIZE(_o->size) - SIZEOF_BINARY32OBJECT)


#define k4ByteAlignmentFlag 0x00000001

#endif	/* __REF32_H */
