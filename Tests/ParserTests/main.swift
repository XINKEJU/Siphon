import Foundation

// HLS playlist + MPEG-DASH MPD parser tests. Run via `scripts/verify.sh`.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

let master = """
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1920x1080
high/index.m3u8
"""
let m = HLSParser.parse(master, baseURL: URL(string: "https://cdn.example.com/master.m3u8")!)
check("HLS master detected", m.isMaster)
check("HLS variant count", m.variants.count == 2)
check("HLS bandwidths", m.variants.map(\.bandwidth) == [800000, 2400000])
check("HLS best variant", HLSParser.bestVariant(m)?.lastPathComponent == "index.m3u8"
      && HLSParser.bestVariant(m)?.absoluteString.contains("/high/") == true)

let media = """
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA-SEQUENCE:7
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/key.bin",IV=0x00000000000000000000000000000001
#EXTINF:10.0,
#EXT-X-BYTERANGE:1000@200
seg7.ts
#EXTINF:10.0,
seg8.ts
#EXT-X-ENDLIST
"""
let p = HLSParser.parse(media, baseURL: URL(string: "https://cdn.example.com/high/index.m3u8")!)
check("HLS media not master", !p.isMaster)
check("HLS segment count (BYTERANGE between EXTINF and URI)", p.segments.count == 2)
check("HLS media sequence", p.mediaSequence == 7)
check("HLS byte range", p.segments.first?.byteRange?.length == 1000
      && p.segments.first?.byteRange?.offset == 200)
check("HLS second segment has nil range", p.segments.last?.byteRange == nil)
check("HLS key URI", p.keyURL?.absoluteString == "https://cdn.example.com/key.bin")
check("HLS key IV length", p.keyIV?.count == 16)
check("HLS relative URL resolves", p.segments.first?.url.absoluteString
      == "https://cdn.example.com/high/seg7.ts")

let mpd = """
<?xml version="1.0"?>
<MPD mediaPresentationDuration="PT30S" xmlns="urn:mpeg:dash:schema:mpd:2011">
 <Period>
  <AdaptationSet mimeType="video/mp4">
   <Representation id="v1" bandwidth="500000">
    <BaseURL>video/</BaseURL>
    <SegmentTemplate timescale="1000" duration="10000" startNumber="1"
                     initialization="init_$RepresentationID$.mp4"
                     media="seg_$Number$_$RepresentationID$.m4s"/>
   </Representation>
   <Representation id="v2" bandwidth="2000000">
    <SegmentTemplate timescale="1000" duration="10000" startNumber="1"
                     initialization="init.mp4" media="seg_$Number$.m4s">
     <SegmentTimeline><S d="10000" r="2"/></SegmentTimeline>
    </SegmentTemplate>
   </Representation>
  </AdaptationSet>
 </Period>
</MPD>
"""
let s = DASHMPDParser.parse(mpd, baseURL: URL(string: "https://cdn.example.com/manifest.mpd")!)
check("DASH stream count", s.count == 2)
check("DASH bandwidths", s.map(\.bandwidth) == [500000, 2000000])
check("DASH $RepresentationID$ in init URL", s[0].initURL?.lastPathComponent == "init_v1.mp4")
check("DASH $Number$ + $RepresentationID$ in media", s[0].segments.first?.url.lastPathComponent == "seg_1_v1.m4s")
check("DASH duration-based segment count", s[0].segments.count == 3)
check("DASH SegmentTimeline segment count (r=2)", s[1].segments.count == 3)
check("DASH timeline first media", s[1].segments.first?.url.lastPathComponent == "seg_1.m4s")
check("ISO8601 PT30S", DASHMPDParser.parseDuration("PT30S") == 30)
check("ISO8601 PT1H2M3S", DASHMPDParser.parseDuration("PT1H2M3S") == 3723)

print(failures == 0 ? "ParserTests: ALL PASS" : "ParserTests: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
