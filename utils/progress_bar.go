package utils

import (
	"io"

	"github.com/vbauerster/mpb/v8"
	"github.com/vbauerster/mpb/v8/decor"
)

func NewProgressBar(output io.Writer) *mpb.Progress {
	p := mpb.New(mpb.WithOutput(output), mpb.WithAutoRefresh(), mpb.WithWidth(80))
	return p
}

func AddBar(p *mpb.Progress, count int, prefix string) *mpb.Bar {
	return 	p.New(int64(count),
		mpb.BarStyle(),
		mpb.PrependDecorators(
			decor.Name(prefix, decor.WC{C: decor.DSyncWidth | decor.DidentRight | decor.DextraSpace}),
		),
		mpb.AppendDecorators(
			decor.CountersNoUnit("%d / %d", decor.WC{C: decor.DSyncWidth | decor.DidentRight | decor.DextraSpace}),
			decor.OnComplete(decor.Percentage(decor.WC{C: decor.DSyncWidth | decor.DidentRight | decor.DextraSpace}), "[COMPLETE]"),
		),
	)
}
