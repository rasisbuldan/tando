package apps

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestNames(t *testing.T) {
	root := t.TempDir()
	mk := func(app, file string) {
		d := filepath.Join(root, "apps", app)
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if file != "" {
			os.WriteFile(filepath.Join(d, file), []byte("port=4100\nrecipe=node\n"), 0o640)
		}
	}
	if got, err := Names(root); err != nil || got != nil {
		t.Fatalf("no apps dir: %v, %v", got, err)
	}
	mk("web", "app.conf")
	mk("api-2", "app.conf")
	mk("half", "")        // destroyed half-way: no app.conf
	mk("Bad", "app.conf") // not a valid name
	mk("x", "app.conf")   // too short
	mk("dir", "")
	os.Mkdir(filepath.Join(root, "apps", "dir", "app.conf"), 0o755) // not a regular file
	got, err := Names(root)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"api-2", "web"}; !slices.Equal(got, want) {
		t.Errorf("Names = %v, want %v", got, want)
	}
	c, err := Conf(root, "web")
	if err != nil || c["port"] != "4100" {
		t.Errorf("Conf = %v, %v", c, err)
	}
	s, err := State(root, "web")
	if err != nil || len(s) != 0 {
		t.Errorf("State of an app without one = %v, %v", s, err)
	}
}
