#import "LBTendiesValidator.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <zlib.h>
#import <errno.h>
#import <limits.h>
#import <string.h>

static NSString * const LBTDomain = @"com.iuyghi.LumenBoard.Tendies";
static const uint64_t LBTMaxArchive = 300ULL * 1024ULL * 1024ULL;
static const uint64_t LBTMaxTotal = 128ULL * 1024ULL * 1024ULL;
static const uint64_t LBTMaxFile = 64ULL * 1024ULL * 1024ULL;
static const NSUInteger LBTMaxEntries = 2048, LBTMaxPlist = 8 * 1024 * 1024;
static NSError *LBTMakeError(NSInteger code, NSString *message) { return [NSError errorWithDomain:LBTDomain code:code userInfo:@{NSLocalizedDescriptionKey:message ?: @"Validation failed"}]; }
static uint16_t LBTU16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }
static uint32_t LBTU32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static BOOL LBTRange(NSUInteger p, NSUInteger n, NSUInteger total) { return p <= total && n <= total-p; }
static NSString *LBTHash(NSData *d) { unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes,(CC_LONG)d.length,h); NSMutableString *s=[NSMutableString string]; for(NSUInteger i=0;i<sizeof(h);i++)[s appendFormat:@"%02x",h[i]]; return s; }

static BOOL LBTNormalizePath(NSString *raw, BOOL dir, NSString **key, NSError **error) {
    if (!raw.length || [raw containsString:@"\\"] || [raw rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) { if(error)*error=LBTMakeError(10,@"Invalid path or separator"); return NO; }
    if ([raw hasPrefix:@"/"] || [raw hasPrefix:@"~"] || (raw.length>1 && [raw characterAtIndex:1]==':')) { if(error)*error=LBTMakeError(11,@"Absolute path rejected"); return NO; }
    NSString *name=(dir&&[raw hasSuffix:@"/"])?[raw substringToIndex:raw.length-1]:raw;
    NSArray *parts=[name componentsSeparatedByString:@"/"];
    for(NSString *part in parts) if(!part.length||[part isEqualToString:@"."]||[part isEqualToString:@".."]||[part containsString:@":"]) { if(error)*error=LBTMakeError(12,@"Path traversal or ambiguous path rejected"); return NO; }
    if(key)*key=[[parts componentsJoinedByString:@"/"] precomposedStringWithCanonicalMapping].lowercaseString;
    return YES;
}
// Finder/macOS archives commonly include a mirrored __MACOSX tree and
// AppleDouble resource-fork files. These are not PosterBoard content. Keep
// validating their ZIP paths, bounds and CRCs, but never parse or extract them.
static BOOL LBTIsMetadataPath(NSString *path) {
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        NSString *lower = component.lowercaseString;
        if ([lower isEqualToString:@"__macosx"] ||
            [lower isEqualToString:@"macosx"] ||
            [lower isEqualToString:@".ds_store"] ||
            [lower hasPrefix:@"._"]) return YES;
    }
    return NO;
}

static BOOL LBTEmitChunk(const uint8_t *bytes, NSUInteger length, uLong *crc, uint64_t *produced, NSMutableData *capture, int outputFD, NSError **error) {
    if(length > LBTMaxFile - *produced){if(error)*error=LBTMakeError(81,@"Decompressed output exceeds member limit");return NO;}
    *crc=crc32(*crc,bytes,(uInt)length);
    *produced+=length;
    if(capture){
        if(length > LBTMaxPlist-capture.length){if(error)*error=LBTMakeError(82,@"Plist exceeds capture limit");return NO;}
        [capture appendBytes:bytes length:length];
    }
    if(outputFD>=0){
        NSUInteger offset=0;
        while(offset<length){
            ssize_t wrote=write(outputFD,bytes+offset,length-offset);
            if(wrote<0&&errno==EINTR)continue;
            if(wrote<=0){if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];return NO;}
            offset+=(NSUInteger)wrote;
        }
    }
    return YES;
}
static NSData *LBTProcessMember(const uint8_t *input, NSUInteger inputLength, NSUInteger expected, uint16_t method, uint32_t expectedCRC, int outputFD, BOOL capture, NSError **error) {
    if(expected>LBTMaxFile||inputLength>UINT_MAX){if(error)*error=LBTMakeError(20,@"Member exceeds supported bounds");return nil;}
    NSMutableData *captured=capture?[NSMutableData dataWithCapacity:MIN(expected,(NSUInteger)LBTMaxPlist)]:nil;
    uint8_t output[64*1024]; uint64_t produced=0; uLong crc=crc32(0L,Z_NULL,0);
    if(method==0){
        if(inputLength!=expected){if(error)*error=LBTMakeError(21,@"Stored member size mismatch");return nil;}
        NSUInteger offset=0;
        while(offset<inputLength){
            NSUInteger chunk=MIN(sizeof(output),inputLength-offset);
            memcpy(output,input+offset,chunk);
            if(!LBTEmitChunk(output,chunk,&crc,&produced,captured,outputFD,error))return nil;
            offset+=chunk;
        }
    }else if(method==8){
        z_stream z={0};
        if(inflateInit2(&z,-MAX_WBITS)!=Z_OK){if(error)*error=LBTMakeError(23,@"Cannot initialize DEFLATE");return nil;}
        z.next_in=(Bytef *)input; z.avail_in=(uInt)inputLength;
        int rc=Z_OK; BOOL ok=YES;
        while(rc!=Z_STREAM_END){
            z.next_out=output; z.avail_out=(uInt)sizeof(output);
            uLong beforeIn=z.total_in,beforeOut=z.total_out;
            rc=inflate(&z,Z_NO_FLUSH);
            NSUInteger chunk=sizeof(output)-z.avail_out;
            if(chunk&&!LBTEmitChunk(output,chunk,&crc,&produced,captured,outputFD,error)){ok=NO;break;}
            if(rc!=Z_OK&&rc!=Z_STREAM_END){if(error)*error=LBTMakeError(24,@"Invalid or truncated DEFLATE stream");ok=NO;break;}
            if(rc!=Z_STREAM_END&&z.total_in==beforeIn&&z.total_out==beforeOut){if(error)*error=LBTMakeError(24,@"DEFLATE stream made no progress");ok=NO;break;}
        }
        BOOL complete=ok&&rc==Z_STREAM_END&&z.total_in==inputLength&&produced==expected;
        inflateEnd(&z);
        if(!complete){if(error)*error=LBTMakeError(24,@"DEFLATE size or input length mismatch");return nil;}
    }else{if(error)*error=LBTMakeError(22,@"Unsupported compression method");return nil;}
    if(produced!=expected||(uint32_t)crc!=expectedCRC){if(error)*error=LBTMakeError(30,@"CRC or uncompressed size mismatch");return nil;}
    return captured?:[NSData data];
}

@interface LBTEntry:NSObject
@property(nonatomic,copy) NSString *name,*key;
@property(nonatomic) uint16_t flags,method;
@property(nonatomic) uint32_t crc,compressed,uncompressed,localOffset,external;
@property(nonatomic) BOOL directory,ignoredMetadata;
@property(nonatomic) uint64_t localHeaderSize,dataOffset,descriptorSize,recordEnd;
@end
@implementation LBTEntry @end

@implementation LBTendiesValidator
+ (NSDictionary *)validateArchiveAtPath:(NSString *)path extractToPath:(NSString *)destination error:(NSError **)error {
    struct stat st;
    if(lstat(path.fileSystemRepresentation,&st)!=0||!S_ISREG(st.st_mode)||S_ISLNK(st.st_mode)||st.st_size<=0||(uint64_t)st.st_size>LBTMaxArchive){if(error)*error=LBTMakeError(1,@"Archive must be a regular non-empty file no larger than 300 MiB");return @{@"status":@"invalid",@"errors":@[@"Unsafe or oversized archive"]};}
    NSError *readError=nil; NSData *zip=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&readError];
    if(!zip){if(error)*error=readError;return @{@"status":@"incomplete",@"errors":@[readError.localizedDescription?:@"Read failed"]};}
    const uint8_t *b=zip.bytes; NSUInteger n=zip.length, eocd=NSNotFound, floor=n>65557?n-65557:0;
    if(n>=22){for(NSUInteger p=n-22;;p--){if(LBTRange(p,4,n)&&LBTU32(b+p)==0x06054b50){eocd=p;break;}if(p==floor)break;}}
    if(eocd==NSNotFound||!LBTRange(eocd,22,n)){if(error)*error=LBTMakeError(2,@"ZIP end record missing");return @{@"status":@"invalid",@"errors":@[@"Malformed ZIP"]};}
    uint16_t disk=LBTU16(b+eocd+4),cdDisk=LBTU16(b+eocd+6),onDisk=LBTU16(b+eocd+8),count=LBTU16(b+eocd+10),comment=LBTU16(b+eocd+20);
    uint32_t cdSize=LBTU32(b+eocd+12),cdOffset=LBTU32(b+eocd+16);
    if(disk||cdDisk||onDisk!=count){if(error)*error=LBTMakeError(3,@"Multi-disk ZIP unsupported");return @{@"status":@"unsupported",@"errors":@[@"Multi-disk ZIP"]};}
    if(count==0xffff||cdSize==0xffffffff||cdOffset==0xffffffff){if(error)*error=LBTMakeError(4,@"ZIP64 unsupported");return @{@"status":@"unsupported",@"errors":@[@"ZIP64"]};}
    if(!count||count>LBTMaxEntries||!LBTRange(eocd,22+comment,n)||eocd+22+(NSUInteger)comment!=n||(uint64_t)cdOffset+cdSize!=eocd){if(error)*error=LBTMakeError(5,@"Invalid central directory");return @{@"status":@"invalid",@"errors":@[@"Invalid central directory"]};}
    NSMutableArray<LBTEntry *> *entries=[NSMutableArray array]; NSMutableSet *keys=[NSMutableSet set]; NSMutableDictionary<NSString *, NSNumber *> *pathKinds=[NSMutableDictionary dictionary]; uint64_t total=0; NSUInteger cursor=cdOffset,ignoredMetadataCount=0; BOOL descriptor=NO,container=NO;
    for(NSUInteger i=0;i<count;i++){
        if(!LBTRange(cursor,46,n)||LBTU32(b+cursor)!=0x02014b50){if(error)*error=LBTMakeError(6,@"Malformed central directory record");return @{@"status":@"invalid",@"errors":@[@"Malformed central directory"]};}
        const uint8_t *h=b+cursor; uint16_t flags=LBTU16(h+8),method=LBTU16(h+10),nl=LBTU16(h+28),xl=LBTU16(h+30),cl=LBTU16(h+32),diskStart=LBTU16(h+34);
        uint32_t crc=LBTU32(h+16),cs=LBTU32(h+20),us=LBTU32(h+24),ext=LBTU32(h+38),local=LBTU32(h+42); NSUInteger record=46+(NSUInteger)nl+xl+cl;
        if(!LBTRange(cursor,record,n)){if(error)*error=LBTMakeError(7,@"Truncated central directory");return @{@"status":@"invalid",@"errors":@[@"Truncated central directory"]};}
        const uint8_t *extraBytes=h+46+nl; NSUInteger extraCursor=0;
        while(extraCursor<xl){
            if(!LBTRange(extraCursor,4,xl)){if(error)*error=LBTMakeError(70,@"Malformed ZIP extra field");return @{@"status":@"invalid",@"errors":@[@"Malformed ZIP extra field"]};}
            uint16_t extraID=LBTU16(extraBytes+extraCursor),extraLength=LBTU16(extraBytes+extraCursor+2); extraCursor+=4;
            if(!LBTRange(extraCursor,extraLength,xl)){if(error)*error=LBTMakeError(71,@"Truncated ZIP extra field");return @{@"status":@"invalid",@"errors":@[@"Truncated ZIP extra field"]};}
            if(extraID==0x0001){if(error)*error=LBTMakeError(72,@"ZIP64 extra field unsupported");return @{@"status":@"unsupported",@"errors":@[@"ZIP64 extra field"]};}
            extraCursor+=extraLength;
        }
        if(diskStart!=0||cs==0xffffffff||us==0xffffffff||local==0xffffffff){if(error)*error=LBTMakeError(8,@"ZIP64 entry unsupported");return @{@"status":@"unsupported",@"errors":@[@"ZIP64 entry"]};}
        NSString *name=[[NSString alloc]initWithBytes:h+46 length:nl encoding:NSUTF8StringEncoding]; if(!name){if(error)*error=LBTMakeError(9,@"Invalid UTF-8 entry name");return @{@"status":@"invalid",@"errors":@[@"Invalid filename encoding"]};}
        uint32_t mode=(ext>>16)&0xffff,kind=mode&0170000;
        // ZIP directory entries are not required to carry a trailing slash:
        // Unix mode bits and the DOS directory attribute are authoritative too.
        BOOL dir=[name hasSuffix:@"/"] || kind==0040000 || (ext&0x10)!=0;
        NSString *key=nil; if(!LBTNormalizePath(name,dir,&key,error))return @{@"status":@"invalid",@"errors":@[@"Unsafe archive path"]};
        if([keys containsObject:key]){if(error)*error=LBTMakeError(13,@"Duplicate, Unicode or case-folded path collision");return @{@"status":@"invalid",@"errors":@[@"Duplicate path"]};}
        // Explicit directory entries may be ancestors of files. Only a file used
        // as an ancestor, or a file replacing a path that already has descendants,
        // is a genuine file/directory collision.
        NSArray<NSString *> *components=[key componentsSeparatedByString:@"/"];
        NSMutableString *ancestor=[NSMutableString string];
        for(NSUInteger componentIndex=0;componentIndex+1<components.count;componentIndex++){
            if(ancestor.length)[ancestor appendString:@"/"];
            [ancestor appendString:components[componentIndex]];
            NSNumber *ancestorKind=pathKinds[ancestor];
            if(ancestorKind && ancestorKind.integerValue==0){
                if(error)*error=LBTMakeError(14,[NSString stringWithFormat:@"File/directory path collision: '%@' is nested under file '%@'",key,ancestor]);
                return @{@"status":@"invalid",@"errors":@[@"Path collision"]};
            }
            // Some ZIP writers encode directory records as zero-byte regular
            // entries with no Unix/DOS directory attributes and no trailing '/'.
            // Promote such an entry only when a descendant proves it is a folder.
            if(ancestorKind && ancestorKind.integerValue==2){
                pathKinds[ancestor]=@1;
                for(LBTEntry *priorEntry in entries) if([priorEntry.key isEqualToString:ancestor]) priorEntry.directory=YES;
            }
        }
        if(!dir){
            NSString *descendantPrefix=[key stringByAppendingString:@"/"];
            BOOL hasDescendant=NO;
            for(NSString *prior in keys) if([prior hasPrefix:descendantPrefix]){hasDescendant=YES;break;}
            if(hasDescendant && us==0){
                // An empty entry that already has descendants is a directory
                // regardless of missing ZIP directory metadata.
                dir=YES;
            }else if(hasDescendant){
                for(NSString *prior in keys) if([prior hasPrefix:descendantPrefix]){
                    if(error)*error=LBTMakeError(14,[NSString stringWithFormat:@"File/directory path collision: file '%@' conflicts with descendant '%@'",key,prior]);
                    return @{@"status":@"invalid",@"errors":@[@"Path collision"]};
                }
            }
        }
        [keys addObject:key];
        pathKinds[key]=@(dir?1:(us==0?2:0));
        if(kind==0120000||(kind&&kind!=0100000&&kind!=0040000)){if(error)*error=LBTMakeError(15,@"Symlink or special entry rejected");return @{@"status":@"invalid",@"errors":@[@"Symlink or special entry"]};}
        if(flags&(1|0x40|0x2000)){if(error)*error=LBTMakeError(16,@"Encrypted entries unsupported");return @{@"status":@"unsupported",@"errors":@[@"Encrypted archive"]};}
        if(method!=0&&method!=8){if(error)*error=LBTMakeError(17,@"Unsupported compression method");return @{@"status":@"unsupported",@"errors":@[@"Unsupported compression"]};}
        if(us>LBTMaxFile||total+us>LBTMaxTotal||(us>0&&(cs==0||(uint64_t)us>(uint64_t)cs*500))){if(error)*error=LBTMakeError(18,@"ZIP bomb/resource bound exceeded");return @{@"status":@"invalid",@"errors":@[@"Decompression limit exceeded"]};}
        total+=us; BOOL ignoredMetadata=LBTIsMetadataPath(name); if(ignoredMetadata)ignoredMetadataCount++;
        if(!ignoredMetadata){NSArray *nameComponents=[name.lowercaseString componentsSeparatedByString:@"/"]; if([nameComponents containsObject:@"container"])container=YES;
            if([nameComponents containsObject:@"descriptor"]||[nameComponents containsObject:@"descriptors"])descriptor=YES;}
        LBTEntry *e=[LBTEntry new];e.name=name;e.key=key;e.flags=flags;e.method=method;e.crc=crc;e.compressed=cs;e.uncompressed=us;e.localOffset=local;e.external=ext;e.directory=dir;e.ignoredMetadata=ignoredMetadata;[entries addObject:e];cursor+=record;
    }
    if(cursor!=cdOffset+cdSize){if(error)*error=LBTMakeError(19,@"Central directory size mismatch");return @{@"status":@"invalid",@"errors":@[@"Central directory mismatch"]};}
    if(container){if(error)*error=LBTMakeError(25,@"Whole-container archives are unsupported");return @{@"status":@"unsupported",@"errors":@[@"Container-format archive"]};}
    if(!descriptor){if(error)*error=LBTMakeError(26,@"Descriptor directory not found");return @{@"status":@"incomplete",@"errors":@[@"Descriptor directory missing"]};}
    NSMutableArray *plists=[NSMutableArray array],*wallpapers=[NSMutableArray array],*occupiedRanges=[NSMutableArray array];
    for(LBTEntry *e in entries){
        NSUInteger p=e.localOffset;
        if(!LBTRange(p,30,n)||LBTU32(b+p)!=0x04034b50){if(error)*error=LBTMakeError(27,@"Invalid local file header");return @{@"status":@"invalid",@"errors":@[@"Invalid local header"]};}
        uint16_t localFlags=LBTU16(b+p+6),localMethod=LBTU16(b+p+8),ln=LBTU16(b+p+26),le=LBTU16(b+p+28);
        if(!LBTRange(p+30,(NSUInteger)ln+le,n)){if(error)*error=LBTMakeError(73,@"Truncated local header fields");return @{@"status":@"invalid",@"errors":@[@"Truncated local header"]};}
        NSUInteger data=p+30+(NSUInteger)ln+le;
        if(localFlags!=e.flags||localMethod!=e.method||!LBTRange(data,e.compressed,n)||data+e.compressed>cdOffset){if(error)*error=LBTMakeError(28,@"Local and central ZIP headers disagree");return @{@"status":@"invalid",@"errors":@[@"Header mismatch or truncated member"]};}
        NSString *localName=[[NSString alloc]initWithBytes:b+p+30 length:ln encoding:NSUTF8StringEncoding];
        if(![localName isEqualToString:e.name]){if(error)*error=LBTMakeError(29,@"Local and central entry names disagree");return @{@"status":@"invalid",@"errors":@[@"Filename mismatch"]};}
        const uint8_t *localExtra=b+p+30+ln; NSUInteger localExtraCursor=0;
        while(localExtraCursor<le){
            if(!LBTRange(localExtraCursor,4,le)){if(error)*error=LBTMakeError(83,@"Malformed local ZIP extra field");return @{@"status":@"invalid",@"errors":@[@"Malformed local extra field"]};}
            uint16_t extraID=LBTU16(localExtra+localExtraCursor),extraLength=LBTU16(localExtra+localExtraCursor+2);localExtraCursor+=4;
            if(!LBTRange(localExtraCursor,extraLength,le)){if(error)*error=LBTMakeError(84,@"Truncated local ZIP extra field");return @{@"status":@"invalid",@"errors":@[@"Truncated local extra field"]};}
            if(extraID==0x0001){if(error)*error=LBTMakeError(85,@"Local ZIP64 extra field unsupported");return @{@"status":@"unsupported",@"errors":@[@"Local ZIP64 extra field"]};}
            localExtraCursor+=extraLength;
        }
        uint32_t localCRC=LBTU32(b+p+14),localCS=LBTU32(b+p+18),localUS=LBTU32(b+p+22);
        if(e.flags&8){
            if((localCRC&&localCRC!=e.crc)||(localCS&&localCS!=e.compressed)||(localUS&&localUS!=e.uncompressed)){if(error)*error=LBTMakeError(74,@"Non-zero local sizes disagree with data descriptor");return @{@"status":@"invalid",@"errors":@[@"Local descriptor fields mismatch"]};}
        }else if(localCRC!=e.crc||localCS!=e.compressed||localUS!=e.uncompressed){
            if(error)*error=LBTMakeError(75,@"Local CRC or sizes disagree with central directory");return @{@"status":@"invalid",@"errors":@[@"Local CRC or size mismatch"]};
        }
        NSUInteger descriptorSize=0,recordEnd=data+e.compressed;
        if(e.flags&8){
            NSUInteger descriptor=recordEnd;
            if(!LBTRange(descriptor,12,cdOffset)){if(error)*error=LBTMakeError(76,@"Truncated ZIP data descriptor");return @{@"status":@"invalid",@"errors":@[@"Truncated data descriptor"]};}
            if(LBTU32(b+descriptor)==0x08074b50){descriptor+=4;descriptorSize=16;}else descriptorSize=12;
            if(!LBTRange(descriptor,12,cdOffset)||LBTU32(b+descriptor)!=e.crc||LBTU32(b+descriptor+4)!=e.compressed||LBTU32(b+descriptor+8)!=e.uncompressed){if(error)*error=LBTMakeError(77,@"ZIP data descriptor mismatch");return @{@"status":@"invalid",@"errors":@[@"Data descriptor mismatch"]};}
            recordEnd+=descriptorSize;
        }
        if(recordEnd>cdOffset){if(error)*error=LBTMakeError(78,@"Local record overlaps central directory");return @{@"status":@"invalid",@"errors":@[@"Record overlaps central directory"]};}
        e.localHeaderSize=30+(uint64_t)ln+le;e.dataOffset=data;e.descriptorSize=descriptorSize;e.recordEnd=recordEnd;
        [occupiedRanges addObject:[NSValue valueWithRange:NSMakeRange(p,recordEnd-p)]];
        if(e.directory){
            // Empty directory entries may themselves be DEFLATE-compressed (for
            // example, a 2-byte raw DEFLATE stream with zero uncompressed bytes).
            // Verify the stream and CRC instead of requiring compressedSize == 0.
            NSError *directoryError=nil;
            NSData *directoryPayload=LBTProcessMember(b+data,e.compressed,e.uncompressed,e.method,e.crc,-1,NO,&directoryError);
            if(!directoryPayload || directoryPayload.length!=0){if(error)*error=directoryError?:LBTMakeError(79,@"Directory entry contains file data");return @{@"status":@"invalid",@"errors":@[directoryError.localizedDescription?:@"Non-empty directory entry"]};}
            continue;
        }
        BOOL isPlist=!e.ignoredMetadata && [e.name.pathExtension.lowercaseString isEqualToString:@"plist"];
        NSError *decodeError=nil;
        NSData *plain=LBTProcessMember(b+data,e.compressed,e.uncompressed,e.method,e.crc,-1,isPlist,&decodeError);
        if(!plain){if(error)*error=decodeError;return @{@"status":@"invalid",@"errors":@[decodeError.localizedDescription?:@"Member validation failed"]};}
        if(isPlist){
            if(plain.length>LBTMaxPlist){if(error)*error=LBTMakeError(31,@"Plist too large");return @{@"status":@"invalid",@"errors":@[@"Oversized plist"]};}
            NSError *pe=nil; id object=[NSPropertyListSerialization propertyListWithData:plain options:NSPropertyListImmutable format:nil error:&pe];
            if(!object){if(error)*error=LBTMakeError(32,[NSString stringWithFormat:@"Malformed plist %@: %@",e.name,pe.localizedDescription]);return @{@"status":@"invalid",@"errors":@[@"Malformed plist"]};}
            [plists addObject:e.name];
            if([e.name.lastPathComponent.lowercaseString isEqualToString:@"wallpaper.plist"]){
                BOOL validID = [object isKindOfClass:NSDictionary.class] &&
                    ([object[@"identifier"] isKindOfClass:NSNumber.class] ||
                     ([object[@"identifier"] isKindOfClass:NSString.class] && [object[@"identifier"] length] > 0));
                if(!validID || ![object[@"name"] isKindOfClass:NSString.class] || ![object[@"assets"] isKindOfClass:NSDictionary.class]){if(error)*error=LBTMakeError(33,@"Wallpaper.plist missing identifier/name/assets");return @{@"status":@"incomplete",@"errors":@[@"Incomplete Wallpaper.plist"]};}
                [wallpapers addObject:e.name];
            }
        }
    }
    [occupiedRanges sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        NSRange ra=a.rangeValue,rb=b.rangeValue;
        if(ra.location<rb.location)return NSOrderedAscending;
        if(ra.location>rb.location)return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSUInteger previousEnd=0;
    for(NSValue *value in occupiedRanges){
        NSRange range=value.rangeValue;
        if(range.location<previousEnd){if(error)*error=LBTMakeError(80,@"ZIP local records overlap");return @{@"status":@"invalid",@"errors":@[@"Overlapping local records"]};}
        previousEnd=NSMaxRange(range);
    }
    if(!wallpapers.count){if(error)*error=LBTMakeError(34,@"No structurally complete Wallpaper.plist");return @{@"status":@"incomplete",@"errors":@[@"Wallpaper.plist missing"]};}
    NSMutableDictionary *report=[@{@"status":@"valid",@"format":@"descriptor",@"archiveBytes":@(zip.length),@"entryCount":@(entries.count),@"ignoredMetadataEntries":@(ignoredMetadataCount),@"uncompressedBytes":@(total),@"sha256":LBTHash(zip),@"plistFiles":plists,@"wallpaperPlists":wallpapers,@"compatibility":@"not-tested",@"validatorVersion":@"1.0.1"} mutableCopy];
    if(destination.length){
        struct stat ds; if(lstat(destination.fileSystemRepresentation,&ds)==0){if(error)*error=LBTMakeError(35,@"Extraction destination already exists");return @{@"status":@"invalid",@"errors":@[@"Destination exists"]};}
        if(mkdir(destination.fileSystemRepresentation,0700)!=0){if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];return @{@"status":@"incomplete",@"errors":@[@"Cannot create extraction root"]};}
        BOOL success=YES; NSError *extractError=nil;
        for(LBTEntry *e in entries){
            if(e.ignoredMetadata)continue;
            NSString *target=[destination stringByAppendingPathComponent:e.name];
            if(e.directory){if(![[NSFileManager defaultManager] createDirectoryAtPath:target withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&extractError]){success=NO;break;}continue;}
            NSString *parent=target.stringByDeletingLastPathComponent;
            if(![[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&extractError]){success=NO;break;}
            NSString *temporary=[parent stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.lumenboard-%@",target.lastPathComponent,NSUUID.UUID.UUIDString]];
            int fd=open(temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL
#ifdef O_NOFOLLOW
                |O_NOFOLLOW
#endif
                ,0600);
            if(fd<0){extractError=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];success=NO;break;}
            NSError *streamError=nil;
            NSData *ignored=LBTProcessMember(b+e.dataOffset,e.compressed,e.uncompressed,e.method,e.crc,fd,NO,&streamError);
            BOOL flushed=(ignored!=nil)&&fsync(fd)==0;
            close(fd);
            if(!flushed||link(temporary.fileSystemRepresentation,target.fileSystemRepresentation)!=0){
                extractError=streamError?:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                unlink(temporary.fileSystemRepresentation);success=NO;break;
            }
            unlink(temporary.fileSystemRepresentation);
        }
        if(!success){[[NSFileManager defaultManager] removeItemAtPath:destination error:nil];if(error)*error=extractError;return @{@"status":@"incomplete",@"errors":@[extractError.localizedDescription?:@"Extraction failed"]};}
        report[@"status"]=@"extracted";report[@"extractedPath"]=destination;
    }
    return report;
}
@end
