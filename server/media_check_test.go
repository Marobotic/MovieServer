package main

import "testing"

func TestClassifyProbe(t *testing.T) {
	cases := []struct {
		name string
		p    checkedProbe
		want string
	}{
		{"web_ready mp4 stereo aac", checkedProbe{Ext: ".mp4", VCodec: "h264", PixFmt: "yuv420p", ACodec: "aac", Channels: 2}, classWebDirect},
		{"web_ready mp4 m4v", checkedProbe{Ext: ".m4v", VCodec: "h264", PixFmt: "yuv420p", ACodec: "mp3", Channels: 1}, classWebDirect},
		{"no audio is fine", checkedProbe{Ext: ".mp4", VCodec: "h264", PixFmt: "yuv420p", ACodec: ""}, classWebDirect},
		{"mp4 ac3 needs audio fix", checkedProbe{Ext: ".mp4", VCodec: "h264", PixFmt: "yuv420p", ACodec: "ac3", Channels: 2}, classQuickFix},
		{"mp4 aac 5.1 needs downmix", checkedProbe{Ext: ".mp4", VCodec: "h264", PixFmt: "yuv420p", ACodec: "aac", Channels: 6}, classQuickFix},
		{"mkv h264 remux", checkedProbe{Ext: ".mkv", VCodec: "h264", PixFmt: "yuv420p", ACodec: "aac", Channels: 2}, classQuickFix},
		{"mov pcm remux", checkedProbe{Ext: ".mov", VCodec: "h264", PixFmt: "yuv420p", ACodec: "pcm_s16le", Channels: 2}, classQuickFix},
		{"mkv ac3 5.1 remux", checkedProbe{Ext: ".mkv", VCodec: "h264", PixFmt: "yuv420p", ACodec: "ac3", Channels: 6}, classQuickFix},
		{"hevc 10bit encode", checkedProbe{Ext: ".mkv", VCodec: "hevc", PixFmt: "yuv420p10le"}, classNeedsEncode},
		{"av1 encode", checkedProbe{Ext: ".mkv", VCodec: "av1", PixFmt: "yuv420p"}, classNeedsEncode},
		{"h264 10bit encode", checkedProbe{Ext: ".mp4", VCodec: "h264", PixFmt: "yuv420p10le"}, classNeedsEncode},
		{"hdr needs tone map", checkedProbe{Ext: ".mkv", VCodec: "h264", PixFmt: "yuv420p", HDR: true}, classNeedsEncode},
		{"mpeg4 encode", checkedProbe{Ext: ".avi", VCodec: "mpeg4", PixFmt: "yuv420p"}, classNeedsEncode},
	}
	for _, tc := range cases {
		got, _ := classifyProbe(&tc.p)
		if got != tc.want {
			t.Errorf("%s: got %s want %s", tc.name, got, tc.want)
		}
	}
}

func TestClassifyRealLibraryProbes(t *testing.T) {
	cases := []struct {
		name string
		p    checkedProbe
		want string
	}{
		{"A View to a Kill", checkedProbe{Ext: ".mp4", VCodec: "h264", PixFmt: "yuv420p", ACodec: "aac", Channels: 2}, classWebDirect},
		{"Skyfall", checkedProbe{Ext: ".mp4", VCodec: "h264", PixFmt: "yuv420p", ACodec: "ac3", Channels: 2}, classQuickFix},
		{"Deadpool webrip mp4", checkedProbe{Ext: ".mp4", VCodec: "h264", PixFmt: "yuv420p", ACodec: "aac", Channels: 6}, classQuickFix},
		{"Unsung Hero", checkedProbe{Ext: ".mkv", VCodec: "h264", PixFmt: "yuv420p", ACodec: "aac", Channels: 2}, classQuickFix},
		{"As You Like It", checkedProbe{Ext: ".mov", VCodec: "h264", PixFmt: "yuv420p", ACodec: "pcm_s16le", Channels: 2}, classQuickFix},
		{"Origin", checkedProbe{Ext: ".mkv", VCodec: "hevc", PixFmt: "yuv420p10le", ACodec: "eac3", Channels: 6}, classNeedsEncode},
		{"I Saw the TV Glow", checkedProbe{Ext: ".mkv", VCodec: "hevc", PixFmt: "yuv420p10le", ACodec: "eac3", Channels: 6}, classNeedsEncode},
	}
	for _, tc := range cases {
		got, _ := classifyProbe(&tc.p)
		if got != tc.want {
			t.Errorf("%s: got %s want %s", tc.name, got, tc.want)
		}
	}
}
