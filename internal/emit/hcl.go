package emit

import (
	"strings"

	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/hashicorp/hcl/v2/hclwrite"
)

// templateTokens is a quoted HCL string in which ${var.NAME} stays an
// interpolation and everything else is literal text, escaped. hclwrite's
// own TokensForValue escapes every ${, which is right for literal text
// and wrong for the variable references a template needs.
func templateTokens(s string) hclwrite.Tokens {
	toks := hclwrite.Tokens{{Type: hclsyntax.TokenOQuote, Bytes: []byte(`"`)}}
	for s != "" {
		i := strings.Index(s, "${var.")
		if i < 0 {
			toks = append(toks, literal(s))
			break
		}
		if i > 0 {
			toks = append(toks, literal(s[:i]))
		}
		end := strings.Index(s[i:], "}")
		name := s[i+len("${var.") : i+end]
		toks = append(toks,
			&hclwrite.Token{Type: hclsyntax.TokenTemplateInterp, Bytes: []byte("${")},
			&hclwrite.Token{Type: hclsyntax.TokenIdent, Bytes: []byte("var")},
			&hclwrite.Token{Type: hclsyntax.TokenDot, Bytes: []byte(".")},
			&hclwrite.Token{Type: hclsyntax.TokenIdent, Bytes: []byte(name)},
			&hclwrite.Token{Type: hclsyntax.TokenTemplateSeqEnd, Bytes: []byte("}")},
		)
		s = s[i+end+1:]
	}
	return append(toks, &hclwrite.Token{Type: hclsyntax.TokenCQuote, Bytes: []byte(`"`)})
}

func literal(s string) *hclwrite.Token {
	esc := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "${", "$${", "%{", "%%{").Replace(s)
	return &hclwrite.Token{Type: hclsyntax.TokenQuotedLit, Bytes: []byte(esc)}
}

// pairsTokens is `[\n ["-flag", "value"],\n ... ]`, one pair per line.
func pairsTokens(pairs [][2]string) hclwrite.Tokens {
	toks := hclwrite.Tokens{
		{Type: hclsyntax.TokenOBrack, Bytes: []byte("[")},
		{Type: hclsyntax.TokenNewline, Bytes: []byte("\n")},
	}
	for _, p := range pairs {
		toks = append(toks, &hclwrite.Token{Type: hclsyntax.TokenOBrack, Bytes: []byte("[")})
		toks = append(toks, templateTokens(p[0])...)
		toks = append(toks, &hclwrite.Token{Type: hclsyntax.TokenComma, Bytes: []byte(",")})
		toks = append(toks, templateTokens(p[1])...)
		toks = append(toks,
			&hclwrite.Token{Type: hclsyntax.TokenCBrack, Bytes: []byte("]")},
			&hclwrite.Token{Type: hclsyntax.TokenComma, Bytes: []byte(",")},
			&hclwrite.Token{Type: hclsyntax.TokenNewline, Bytes: []byte("\n")})
	}
	return append(toks, &hclwrite.Token{Type: hclsyntax.TokenCBrack, Bytes: []byte("]")})
}
