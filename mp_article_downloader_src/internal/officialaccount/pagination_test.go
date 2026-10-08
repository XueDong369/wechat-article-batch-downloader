package officialaccount

import (
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestNormalizeMsgPaginationUsesForwardOffset(t *testing.T) {
	tests := []struct {
		name   string
		data   OfficialMsgListResp
		offset int
		more   int
	}{
		{name: "wechat flag is stale", data: OfficialMsgListResp{HasMore: 0, MsgCount: 10, NextOffset: 20}, offset: 10, more: 1},
		{name: "empty terminal page", data: OfficialMsgListResp{HasMore: 1, MsgCount: 0, NextOffset: 20}, offset: 20, more: 0},
		{name: "non advancing page", data: OfficialMsgListResp{HasMore: 1, MsgCount: 10, NextOffset: 20}, offset: 20, more: 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			normalizeMsgPagination(&tt.data, tt.offset)
			if tt.data.HasMore != tt.more {
				t.Fatalf("HasMore = %d, want %d", tt.data.HasMore, tt.more)
			}
		})
	}
}

func TestMergeFromKeepsNewestAuthorID(t *testing.T) {
	acct := &OfficialAccount{AuthorId: "old"}
	acct.MergeFrom(&OfficialAccount{AuthorId: "new"})
	if acct.AuthorId != "new" {
		t.Fatalf("AuthorId = %q", acct.AuthorId)
	}
}

func TestCollectArticleHistoryUsesLastMidCursor(t *testing.T) {
	var cursors []string
	history, err := collectArticleHistory(func(cursor string) (*ArticleListResponse, error) {
		cursors = append(cursors, cursor)
		switch cursor {
		case "":
			return &ArticleListResponse{Articles: []Article{{Mid: "3", Title: "three"}, {Mid: "2", Title: "two"}}}, nil
		case "2":
			return &ArticleListResponse{Articles: []Article{{Mid: "2", Title: "duplicate"}, {Mid: "1", Title: "one"}}}, nil
		case "1":
			return &ArticleListResponse{Articles: []Article{}}, nil
		default:
			t.Fatalf("unexpected cursor %q", cursor)
			return nil, nil
		}
	}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(cursors, []string{"", "2", "1"}) {
		t.Fatalf("cursors = %#v", cursors)
	}
	if history.Pages != 3 || len(history.Articles) != 3 {
		t.Fatalf("history = %+v", history)
	}
}

func TestCollectArticleHistoryRejectsStalledCursor(t *testing.T) {
	_, err := collectArticleHistory(func(string) (*ArticleListResponse, error) {
		return &ArticleListResponse{Articles: []Article{{Mid: "same"}}}, nil
	}, 2)
	if err == nil {
		t.Fatal("accepted stalled cursor")
	}
}

func TestRememberAuthorIDPersistsCapturedRequestValue(t *testing.T) {
	oldPath := mp_json_filepath
	acct_mu.Lock()
	oldAccounts := accounts
	accounts = map[string]*OfficialAccount{"biz": {Biz: "biz"}}
	acct_mu.Unlock()
	mp_json_filepath = filepath.Join(t.TempDir(), "mp.json")
	t.Cleanup(func() {
		mp_json_filepath = oldPath
		acct_mu.Lock()
		accounts = oldAccounts
		acct_mu.Unlock()
	})

	rememberAuthorID("biz", "author")
	acct_mu.RLock()
	got := accounts["biz"].AuthorId
	acct_mu.RUnlock()
	if got != "author" {
		t.Fatalf("AuthorId = %q", got)
	}
	if _, err := os.Stat(mp_json_filepath); err != nil {
		t.Fatal(err)
	}
	rememberAuthorID("biz", "")
	acct_mu.RLock()
	got = accounts["biz"].AuthorId
	acct_mu.RUnlock()
	if got != "author" {
		t.Fatalf("blank capture replaced AuthorId: %q", got)
	}
}

// TestLiveFirstPageOneRequest is opt-in. It only reads the existing account
// credentials into memory and makes a single getmsg request to the official
// WeChat host. It never starts the desktop app, changes system proxy/certs,
// follows redirects, writes account state, paginates, or downloads articles.
func TestLiveFirstPageOneRequest(t *testing.T) {
	if os.Getenv("MP_ARCHIVE_ONE_PAGE_TEST") != "yes" {
		t.Skip("live test requires explicit opt-in")
	}
	accountPath := os.Getenv("MP_ARCHIVE_ACCOUNT_FILE")
	if accountPath == "" {
		t.Fatal("missing account file path")
	}
	contents, err := os.ReadFile(accountPath)
	if err != nil {
		t.Fatal("account file unavailable")
	}
	var saved map[string]*OfficialAccount
	if err := json.Unmarshal(contents, &saved); err != nil {
		t.Fatal("account file invalid")
	}
	var selected *OfficialAccount
	matches := 0
	for _, acct := range saved {
		if acct != nil && acct.Nickname == "罕见病信息网" {
			selected = acct
			matches++
		}
	}
	if matches != 1 {
		t.Fatalf("target account match count: %d; no request sent", matches)
	}
	if selected.Biz == "" || selected.Uin == "" || selected.Key == "" || selected.PassTicket == "" {
		t.Fatal("target account credentials incomplete; no request sent")
	}

	client := &OfficialAccountClient{}
	target := client.BuildMsgListURL(selected, 0)
	params := url.Values{
		"action":      {"home"},
		"__biz":       {selected.Biz},
		"scene":       {"124"},
		"uin":         {selected.Uin},
		"key":         {selected.Key},
		"devicetype":  {"UnifiedPCWindows"},
		"version":     {"f2541022"},
		"lang":        {"zh_CN"},
		"a8scene":     {"1"},
		"acctmode":    {"0"},
		"pass_ticket": {selected.PassTicket},
	}
	referer := "https://mp.weixin.qq.com/mp/profile_ext?" + params.Encode()
	req, err := http.NewRequest("GET", target, nil)
	if err != nil {
		t.Fatal("could not construct first-page request")
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("accept-language", "en-US,en;q=0.9")
	req.Header.Set("priority", "u=1, i")
	req.Header.Set("referer", referer)
	req.Header.Set("sec-fetch-dest", "empty")
	req.Header.Set("sec-fetch-mode", "cors")
	req.Header.Set("sec-fetch-site", "same-origin")
	req.Header.Set("user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36 NetType/WIFI MicroMessenger/7.0.20.1781(0x6700143B) WindowsWechat(0x63090a13) UnifiedPCWindowsWechat(0xf2541022) XWEB/16467 Flue")

	transport := &http.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{
		Transport: transport,
		Timeout:   15 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		t.Fatal("one-request test failed: connection or TLS error (details withheld)")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Logf("FIRST_PAGE http_status=%d redirect_followed=false", resp.StatusCode)
		return
	}
	var page OfficialMsgListResp
	if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&page); err != nil {
		t.Log("FIRST_PAGE http_status=200 json_decode=failed")
		return
	}
	t.Logf("FIRST_PAGE http_status=200 ret=%d msg_count=%d next_offset=%d can_msg_continue=%d payload_present=%t requested_offset=0", page.Ret, page.MsgCount, page.NextOffset, page.HasMore, page.MsgList != "")
}

// TestLiveAuthorFirstPage is independently opt-in. No cookie refresh or retry:
// lacking existing author credentials stops before any network traffic.
func TestLiveAuthorFirstPage(t *testing.T) {
	if os.Getenv("MP_ARCHIVE_AUTHOR_PAGE_TEST") != "yes" {
		t.Skip("author-page request requires explicit opt-in")
	}
	contents, err := os.ReadFile(os.Getenv("MP_ARCHIVE_ACCOUNT_FILE"))
	if err != nil {
		t.Fatal("account file unavailable; no request sent")
	}
	var saved map[string]*OfficialAccount
	if json.Unmarshal(contents, &saved) != nil {
		t.Fatal("account file invalid; no request sent")
	}
	var acct *OfficialAccount
	matches := 0
	for _, item := range saved {
		if item != nil && item.Nickname == "罕见病信息网" {
			acct = item
			matches++
		}
	}
	if matches != 1 {
		t.Fatalf("target account match count=%d; no request sent", matches)
	}
	if acct.AuthorId == "" || acct.AppmsgToken == "" || acct.Cookie == "" || acct.CookieExpiration <= time.Now().Unix() || acct.Uin == "" || acct.Key == "" || acct.PassTicket == "" || acct.Biz == "" {
		t.Logf("AUTHOR_PAGE no_request=missing_or_expired_saved_credential author_id=%t appmsg_token=%t cookie=%t cookie_expired=%t", acct.AuthorId != "", acct.AppmsgToken != "", acct.Cookie != "", acct.CookieExpiration <= time.Now().Unix())
		return
	}
	endpoint := &url.URL{Scheme: "https", Host: "mp.weixin.qq.com", Path: "/mp/author"}
	q := endpoint.Query()
	for key, value := range map[string]string{"action": "get_articles", "author_id": acct.AuthorId, "scene": "142", "limit": "30", "version": "undefined", "appmsg_token": acct.AppmsgToken, "x5": "0", "f": "json", "user_article_role": "0"} {
		q.Set(key, value)
	}
	endpoint.RawQuery = q.Encode()
	ref := url.Values{}
	for key, value := range map[string]string{"action": "show", "__biz": acct.Biz, "idx": "1", "author_id": acct.AuthorId, "scene": "142", "rscene": "128", "uin": acct.Uin, "key": acct.Key, "devicetype": "UnifiedPCMac", "version": "f2640619", "lang": "zh_CN", "ascene": "1", "acctmode": "0", "pass_ticket": acct.PassTicket, "countrycode": "CN"} {
		ref.Set(key, value)
	}
	req, err := http.NewRequest("GET", endpoint.String(), nil)
	if err != nil {
		t.Fatal("author request construction failed")
	}
	req.Header.Set("Cookie", acct.Cookie)
	req.Header.Set("accept", "*/*")
	req.Header.Set("accept-language", "zh-CN,zh;q=0.9")
	req.Header.Set("priority", "u=1, i")
	req.Header.Set("referer", "https://mp.weixin.qq.com/mp/author?"+ref.Encode())
	req.Header.Set("sec-ch-ua", `"Google Chrome";v="143", "Chromium";v="143", "Not A(Brand";v="24"`)
	req.Header.Set("sec-ch-ua-mobile", "?0")
	req.Header.Set("sec-ch-ua-platform", `"macOS"`)
	req.Header.Set("sec-fetch-dest", "empty")
	req.Header.Set("sec-fetch-mode", "cors")
	req.Header.Set("sec-fetch-site", "same-origin")
	req.Header.Set("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36")
	req.Header.Set("x-requested-with", "XMLHttpRequest")
	transport := &http.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal("author request network/TLS error; details withheld")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Logf("AUTHOR_PAGE http_status=%d no_redirect_followed=true", resp.StatusCode)
		return
	}
	var page ArticleListResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&page); err != nil {
		t.Log("AUTHOR_PAGE http_status=200 json_decode=failed")
		return
	}
	t.Logf("AUTHOR_PAGE http_status=200 ret=%d base_ret=%d article_count=%d has_cursor=%t", page.Ret, page.BaseResp.Ret, len(page.Articles), page.MaxArticleID != "")
}
