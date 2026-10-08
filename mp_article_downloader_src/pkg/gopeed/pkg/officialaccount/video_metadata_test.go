package officialaccountdownload

import (
	"encoding/json"
	"testing"
)

func TestVideoMetadataAcceptsStringOrNumberIdentifiers(t *testing.T) {
	for _, raw := range []string{
		`{"video_page_infos":[{"video_id":"abc","hit_username":"wxid_user","hit_bizuin":"123","videoid_bizuin":"456"}]}`,
		`{"video_page_infos":[{"video_id":"abc","hit_username":0,"hit_bizuin":123,"videoid_bizuin":456}]}`,
	} {
		var data CgiDataNew
		if err := json.Unmarshal([]byte(raw), &data); err != nil {
			t.Fatalf("decode video metadata: %v", err)
		}
		if len(data.VideoPageInfos) != 1 || data.VideoPageInfos[0].VideoID != "abc" {
			t.Fatalf("video metadata lost: %+v", data.VideoPageInfos)
		}
	}
}
