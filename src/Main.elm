module Main exposing (main)

{-| The shen-meta documentation site as a plain `Browser.element` app.

This module renders all 5 pages (landing, architecture, build, primitives,
playground) using the shared `Fixpoint.*` design package. It mirrors the
visage / datalog-dafsa docs site structure exactly: one Elm bundle, one MFE
module (`shell/mfe/shen-page.js`), and a `{ pathname }` flag that selects
which page to render. The playground page hosts a `<shen-playground>` custom
element (registered by `shell/mfe/shen-playground.js`) that boots the real
zincvm C VM compiled to WebAssembly and pipes it through an xterm.js terminal.

-}

import Browser
import Fixpoint.Callout
import Fixpoint.Checks
import Fixpoint.Code
import Fixpoint.Cta
import Fixpoint.Footer
import Fixpoint.Grid
import Fixpoint.Headline
import Fixpoint.Hero
import Fixpoint.Nav
import Fixpoint.Section
import Fixpoint.Style
import Html exposing (Attribute, Html, a, b, code, div, em, h3, li, node, p, span, strong, table, tbody, td, text, th, thead, tr, ul)
import Html.Attributes exposing (alt, attribute, class, href, src)


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


type alias Flags =
    { pathname : String }


type Page
    = Landing
    | Architecture
    | Build
    | Primitives
    | Playground


type alias Model =
    Page


type Msg
    = NoOp


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( parsePage (stripShenPrefix flags.pathname), Cmd.none )


{-| Strip a leading `/shen` prefix and any surrounding slashes so the result
is the bare sub-page slug (e.g. `"/shen/playground/"` -> `"playground"`,
`"/shen/"` -> `""`). Falls back to `""` for `/`.
-}
stripShenPrefix : String -> String
stripShenPrefix raw =
    let
        withoutPrefix =
            if String.startsWith "/shen" raw then
                String.dropLeft (String.length "/shen") raw

            else if raw == "/" then
                ""

            else
                raw
    in
    withoutPrefix
        |> String.dropLeft (if String.startsWith "/" withoutPrefix then 1 else 0)
        |> (\s -> if String.endsWith "/" s then String.dropRight 1 s else s)


parsePage : String -> Page
parsePage path =
    case path of
        "" ->
            Landing

        "architecture" ->
            Architecture

        "build" ->
            Build

        "primitives" ->
            Primitives

        "playground" ->
            Playground

        _ ->
            Landing


update : Msg -> Model -> ( Model, Cmd Msg )
update _ model =
    ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none


view : Model -> Html Msg
view model =
    div [] [ Fixpoint.Style.stylesheet, navView, pageView model, footerView ]



-- Route helpers (absolute hrefs + `data-mfe-route` for in-shell nav)


routeHref : String -> String
routeHref sub =
    "https://fixpointlinux.org/shen" ++ sub ++ "/"


routeAttr : String -> Attribute Msg
routeAttr sub =
    attribute "data-mfe-route" ("/shen" ++ sub)


docLink : String -> String -> Html Msg
docLink sub label =
    a [ href (routeHref sub), routeAttr sub ] [ text label ]



-- Top nav


navView : Html Msg
navView =
    Fixpoint.Nav.view
        { brand =
            span []
                [ span [ class "fx" ] [ text "fx" ]
                , text "://shen"
                ]
        , links =
            [ docLink "" "Overview"
            , docLink "/architecture" "Architecture"
            , docLink "/build" "Build"
            , docLink "/primitives" "Primitives"
            ]
        , extra =
            [ a [ class "home", href (routeHref "/playground"), routeAttr "/playground" ] [ text "Playground" ]
            , a [ class "home", href "https://fixpointlinux.org/", attribute "data-mfe-route" "/" ] [ text "fixpoint-linux" ]
            ]
        }


pageView : Model -> Html Msg
pageView model =
    case model of
        Landing ->
            landingView

        Architecture ->
            architectureView

        Build ->
            buildView

        Primitives ->
            primitivesView

        Playground ->
            playgroundView


footerView : Html Msg
footerView =
    Fixpoint.Footer.view
        [ text "shen-meta source lives in "
        , a [ href "https://github.com/fixpoint-linux/shen-meta" ] [ text "github.com/fixpoint-linux/shen-meta" ]
        , Fixpoint.Footer.sep
        , text "part of "
        , a [ href "https://fixpointlinux.org" ] [ text "fixpoint-linux" ]
        ]



-- Landing


landingView : Html Msg
landingView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " shen "
                , Fixpoint.Hero.dollar
                , text " ./zincvm globals.csexp --meta-repl"
                , Fixpoint.Hero.blink
                ]
            , title =
                [ text "A language that "
                , Fixpoint.Hero.fx [ text "evaluates itself" ]
                , text "."
                ]
            , tagline =
                [ text "self-hosted Shen — a C11 VM · custom moving generational GC · ~295 bundled closures · no host runtime"
                ]
            }
        , Fixpoint.Section.view
            { id = "thesis"
            , title = "The self-hosting thesis"
            , hint = "// Shen evaluates Shen, compiles itself to native bytecode, runs on a C VM"
            , children =
                [ p []
                    [ text "The full "
                    , strong [] [ text "eval-kl chain" ]
                    , text " is working: "
                    , Fixpoint.Code.inline "(+ 1 2)"
                    , text " marshalled to tagged form, compiled through the metacircular pipeline, executed by the metacircular interpreter, demarshalled back to native — it returns "
                    , Fixpoint.Code.inline "3"
                    , text ". "
                    , strong [] [ text "Pure self-hosting, no C bypass."
                    ]
                    ]
                , p []
                    [ text "The meta-circular evaluator is the core — the ZINC abstract machine implemented in ~100 lines of Shen pattern-matching rules, serialized to ~0.33 MB of bytecode, and loaded by a ~2600-line C VM with a custom moving generational garbage collector. The VM is self-contained: a working Shen runtime that depends only on a C compiler and its own GC — "
                    , em [] [ text "no Boehm, no host runtime."
                    ]
                    ]
                , Fixpoint.Cta.view
                    { body =
                        [ strong [] [ text "Run it in your browser" ]
                        , text " — the real C VM, compiled to WebAssembly, in an xterm.js terminal. No setup, no server."
                        ]
                    , href = routeHref "/playground"
                    , label = "Open the Playground →"
                    , attrs = [ routeAttr "/playground" ]
                    }
                , Fixpoint.Checks.view
                    [ li [] [ b [] [ text "Evaluates itself" ], text " — the metacircular interpreter is written in Shen and runs on the C VM." ]
                    , li [] [ b [] [ text "Compiles itself" ], text " — the reduced bundle is compiled by our own ", Fixpoint.Code.inline "shen->kl", text " compiler, no Shen OS code." ]
                    , li [] [ b [] [ text "Own garbage collector" ], text " — a custom moving generational collector (nursery + old-gen, precise roots, write barrier)." ]
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "pipeline"
            , title = "The pipeline"
            , hint = "// Shen source → KLambda → ZINC bytecode → C VM"
            , children =
                [ Fixpoint.Code.block
                    [ text "Shen source → shen->kl (own compiler) → KLambda → kmacros → normalize → debruijn\n"
                    , text "            → zinc-c → csexp → C VM\n"
                    , text "                                        ↑\n"
                    , text "             interp.shen (meta-circular ZINC VM on Shen/Chez)\n"
                    , text "                    ↓\n"
                    , text "  serialize-reduced → globals.csexp → C VM (self-hosting)"
                    ]
                , p []
                    [ text "Every stage — the Shen→KLambda front-end, the normalizer, the ZINC compiler, the metacircular interpreter, the serializer — is part of this repo. "
                    , docLink "/architecture" "The full architecture walk-through →"
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "features"
            , title = "Feature summary"
            , hint = "// the stack in one table"
            , children =
                [ table [ class "features" ]
                    [ thead []
                        [ tr []
                            [ th [] [ text "Layer" ]
                            , th [] [ text "What it does" ]
                            ]
                        ]
                    , tbody []
                        [ tr []
                            [ td [ class "name" ] [ text "shen->kl" ]
                            , td [] [ text "Own full-arity Shen→KLambda compiler (safe subset, no partial application)." ]
                            ]
                        , tr []
                            [ td [ class "name" ] [ text "normalize" ]
                            , td [] [ text "KLambda expansion, A-normal form, debruijn indices." ]
                            ]
                        , tr []
                            [ td [ class "name" ] [ text "zinc-c" ]
                            , td [] [ text "KLambda → ZINC bytecode, incl. ", Fixpoint.Code.inline "%%", text " primitive dispatch." ]
                            ]
                        , tr []
                            [ td [ class "name" ] [ text "interp" ]
                            , td [] [ text "The ZINC interpreter in Shen — loads, compiles, and runs." ]
                            ]
                        , tr []
                            [ td [ class "name" ] [ text "zincvm.c" ]
                            , td [] [ text "The native C parser + VM — all primitives, closures, tail calls, custom GC." ]
                            ]
                        , tr []
                            [ td [ class "name" ] [ text "zincdec" ]
                            , td [] [ text "Standalone bytecode decompiler — 4 output formats + ", Fixpoint.Code.inline "--curried", text " scan." ]
                            ]
                        ]
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "selfhost"
            , title = "Proven self-hosting"
            , hint = "// the eval-kl chain, end to end"
            , children =
                [ Fixpoint.Headline.view
                    [ Fixpoint.Headline.card
                        { n = "1"
                        , title = [ text "Marshal" ]
                        , body =
                            [ p [] [ text "Native values are marshalled to tagged Shen forms through the ", Fixpoint.Code.inline "marshal_to_tagged", text " layer." ]
                            ]
                        }
                    , Fixpoint.Headline.card
                        { n = "2"
                        , title = [ text "Compile" ]
                        , body =
                            [ p [] [ text "The tagged form goes ", Fixpoint.Code.inline "extract-kl → kl→zinc → toplevel-interp", text " — compiled entirely by our own compiler." ]
                            ]
                        }
                    , Fixpoint.Headline.card
                        { n = "3"
                        , title = [ text "Execute" ]
                        , body =
                            [ p [] [ text "The metacircular ", Fixpoint.Code.inline "interp", text " (97 pattern-match rules in ", Fixpoint.Code.inline "shen/interp.shen", text ") runs the bytecode on the C VM." ]
                            ]
                        }
                    , Fixpoint.Headline.card
                        { n = "4"
                        , title = [ text "Demarshal" ]
                        , body =
                            [ p [] [ text "The result demarshals back to a native value. ", Fixpoint.Code.inline "(+ 1 2)", text " → ", Fixpoint.Code.inline "3", text ". Shen compiles Shen, which runs on Shen, on the C VM." ]
                            ]
                        }
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "reference"
            , title = "Reference pages"
            , hint = "// architecture · build · primitives · playground"
            , children =
                [ ul []
                    [ li [] [ docLink "/architecture" "Architecture", text " — the pipeline, the two global namespaces, and the design intent." ]
                    , li [] [ docLink "/build" "Build", text " — make targets, the decompiler, tracing, and the self-hosting test matrix." ]
                    , li [] [ docLink "/primitives" "Primitives", text " — the type-checked safe wrappers and ZINC argument convention." ]
                    , li [] [ docLink "/playground" "Playground", text " — the C VM compiled to WebAssembly, in an xterm.js terminal." ]
                    ]
                ]
            }
        ]



-- Architecture


architectureView : Html Msg
architectureView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " shen "
                , Fixpoint.Hero.dollar
                , text " ./zincdec globals.csexp reverse --asm"
                , Fixpoint.Hero.blink
                ]
            , title = [ text "Architecture" ]
            , tagline = []
            }
        , Fixpoint.Section.view
            { id = "pipeline"
            , title = "The compile pipeline"
            , hint = "// Shen → kmacros → normalize → debruijn → zinc-c → csexp → C VM"
            , children =
                [ p []
                    [ text "Shen source is compiled through a fully in-repo pipeline. "
                    , Fixpoint.Code.inline "shen->kl"
                    , text " (our own full-arity Shen→KLambda compiler) feeds "
                    , Fixpoint.Code.inline "kmacros"
                    , text ", "
                    , Fixpoint.Code.inline "normalize-term"
                    , text " (KLambda expansion, A-normal form, debruijn indices), "
                    , Fixpoint.Code.inline "zinc-c"
                    , text " (KLambda → ZINC bytecode), and "
                    , Fixpoint.Code.inline "compile-zinc"
                    , text " (→ canonical s-expressions), landing in "
                    , Fixpoint.Code.inline "nat->csexp"
                    , text " and finally the C VM."
                    ]
                , Fixpoint.Code.block
                    [ text "Shen source → kmacros → normalize-term → debruijn → zinc-c → compile-zinc → nat->csexp → C VM"
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "namespaces"
            , title = "Two global namespaces"
            , hint = "// the #1 source of 'why can't the C VM see my closure?' bugs"
            , children =
                [ p []
                    [ text "There are two separate global tables. The "
                    , strong [] [ text "C VM native "
                    , Fixpoint.Code.inline "global_table[]"
                    , text ""
                    ]
                    , text " (populated by "
                    , Fixpoint.Code.inline "parse_bundle"
                    , text " from the bundle and by "
                    , Fixpoint.Code.inline "init_globals"
                    , text ") is what raw C bytecode "
                    , Fixpoint.Code.inline "[global X]"
                    , text " reaches. The "
                    , strong [] [ text "metacircular interp's Shen "
                    , Fixpoint.Code.inline "global-table"
                    , text ""
                    ]
                    , text " (an assoc list in "
                    , Fixpoint.Code.inline "interp.shen"
                    , text ") is how the interp resolves "
                    , Fixpoint.Code.inline "[global G]"
                    , text " via "
                    , Fixpoint.Code.inline "lookup-global"
                    , text "."
                    ]
                , Fixpoint.Callout.note
                    [ text "A runtime-loaded closure ("
                    , code [] [ text "shen.foo" ]
                    , text ") lives in the interp's Shen "
                    , code [] [ text "global-table" ]
                    , text " (namespace 2) — NOT its own C "
                    , code [] [ text "global_table[]" ]
                    , text " entry. To call it, drive it through the metacircular interp: "
                    , code [] [ text "eval-kl" ]
                    , text ", "
                    , code [] [ text "toplevel-interp" ]
                    , text ", or a bundled closure that resolves names via "
                    , code [] [ text "lookup-global" ]
                    , text "."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "design-intent"
            , title = "Design intent"
            , hint = "// static sites skip safe wrappers; dynamic sites need them"
            , children =
                [ p []
                    [ text "Call sites split into two kinds. "
                    , strong [] [ text "Static" ]
                    , text " call sites — code produced by the compiler, type-safe by construction — need no runtime type check and no safe wrapper; "
                    , Fixpoint.Code.inline "zinc-c"
                    , text " special-cases "
                    , Fixpoint.Code.inline "primitive?"
                    , text " heads to emit "
                    , Fixpoint.Code.inline "[prim F]"
                    , text ", a direct primitive dispatch that bypasses the global table. "
                    , strong [] [ text "Dynamic" ]
                    , text " call sites — boundaries, higher-order use, untyped input — route through the Shen safe wrappers ("
                    , Fixpoint.Code.inline "safe.X"
                    , text ") so a type error becomes a catchable "
                    , Fixpoint.Code.inline "simple-error"
                    , text "."
                    ]
                , Fixpoint.Callout.warn
                    [ text "The C primitives have "
                    , strong [] [ text "no runtime type guards" ]
                    , text ". Type validation is owned entirely by the Shen safe-wrapper layer. This is safe only for a type-safe bundle — the canonical "
                    , code [] [ text "globals.csexp" ]
                    , text " is the reduced self-contained interpreter, which never passes bad types."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "gc"
            , title = "A custom moving generational GC"
            , hint = "// nursery + old-gen · precise roots · write barrier"
            , children =
                [ p []
                    [ text "A 2 MB nursery (pages marked "
                    , Fixpoint.Code.inline "space==3"
                    , text ") is the allocation fast lane; the full-copy "
                    , Fixpoint.Code.inline "collect()"
                    , text " is the (rare) old-gen collector and compacts old gen. Typed headers drive a tag-dispatch scavenger; roots are precise-only via the shadow stack + typed walkers — "
                    , strong [] [ text "no conservative C-stack scan" ]
                    , text ". A write barrier at "
                    , Fixpoint.Code.inline "address->"
                    , text " vector writes keeps old-gen→nursery references correct."
                    ]
                , p []
                    [ text "The same collector runs under WebAssembly in the playground — the wasm build swaps the 4 GB mmap reservation for an "
                    , Fixpoint.Code.inline "aligned_alloc"
                    , text " heap via a "
                    , Fixpoint.Code.inline "#ifdef __wasm__"
                    , text " shim, and a 5000-eval GC stress probe stays clean."
                    ]
                ]
            }
        ]



-- Build


buildView : Html Msg
buildView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " shen "
                , Fixpoint.Hero.dollar
                , text " make && make test"
                , Fixpoint.Hero.blink
                ]
            , title = [ text "Build & run" ]
            , tagline = []
            }
        , Fixpoint.Section.view
            { id = "build"
            , title = "Make targets"
            , hint = "// zincvm · zinctest · zincdec · globals.csexp"
            , children =
                [ Fixpoint.Code.block
                    [ text "git clone --recurse-submodules https://github.com/fixpoint-linux/shen-meta.git\n"
                    , text "cd shen-meta\n"
                    , text "make setup    # clone shen-scheme if not already present\n"
                    , text "make          # build C VM + decompiler (uses cosmocc, Cosmopolitan)\n"
                    , text "make test     # run 34 built-in bytecode tests\n"
                    , text "make pipeline # compile (+ 1 2) through full pipeline\n"
                    , text "make bundle   # compile bundle .shen via shen->kl → globals.csexp\n"
                    , text "make run-bundle  # run C VM with self-hosting bundle\n"
                    , text "make gate     # test + test-asan"
                    ]
                , p []
                    [ text "Requires "
                    , Fixpoint.Code.inline "shen-scheme"
                    , text " (Shen 41.2 on Chez Scheme) at "
                    , Fixpoint.Code.inline "vendor/shen-scheme/"
                    , text " to bootstrap the serializer. The shipped bundle is compiled by our own "
                    , Fixpoint.Code.inline "shen->kl"
                    , text "."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "decompiler"
            , title = "Bytecode decompiler"
            , hint = "// ./zincdec globals.csexp <function> [--raw|--asm|--shen|--csexp]"
            , children =
                [ p []
                    [ text "Standalone binary for inspecting bundled bytecode. Four output formats plus a "
                    , Fixpoint.Code.inline "--curried"
                    , text " scan that flags curried partial-application calls (which the C VM can't run) and exits 1 if any are found."
                    ]
                , Fixpoint.Code.block
                    [ text "./zincdec globals.csexp reverse --asm\n"
                    , text "0000: pushmark\n"
                    , text "0001: number 0\n"
                    , text "0002: prim emptylist\n"
                    , text "0003: access 0\n"
                    , text "0004: global shen.reverse-help\n"
                    , text "0005: appterm"
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "trace"
            , title = "Per-closure tracing"
            , hint = "// ./zincvm globals.csexp --trace + --trace reverse"
            , children =
                [ p []
                    [ text "Trace execution of specific closures as they run, showing each instruction in raw format with PC numbers. Traces only the named function — not functions it calls unless you "
                    , Fixpoint.Code.inline "--trace"
                    , text " them too."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "tests"
            , title = "Self-hosting test matrix"
            , hint = "// 34 built-in VM tests + 10 self-hosting tests + GC stress"
            , children =
                [ table [ class "features" ]
                    [ thead []
                        [ tr []
                            [ th [] [ text "Test" ]
                            , th [] [ text "What it proves" ]
                            ]
                        ]
                    , tbody []
                        [ tr [] [ td [ class "name" ] [ text "1" ], td [] [ text "(+ 1 2) via bundled + → ", Fixpoint.Code.inline "3" ] ]
                        , tr [] [ td [ class "name" ] [ text "2" ], td [] [ text "(reverse [1 2 3]) → ", Fixpoint.Code.inline "[3 2 1]" ] ]
                        , tr [] [ td [ class "name" ] [ text "3" ], td [] [ text "(factorial 5) → ", Fixpoint.Code.inline "120" ] ]
                        , tr [] [ td [ class "name" ] [ text "A/B/C" ], td [] [ text "toplevel-interp / interp on tag forms" ] ]
                        , tr [] [ td [ class "name" ] [ text "5" ], td [] [ text "eval-kl [+ 1 2] via marshal chain → ", Fixpoint.Code.inline "3" ] ]
                        , tr [] [ td [ class "name" ] [ text "6-7" ], td [] [ text "read-file-as-string / load via bundled chain" ] ]
                        , tr [] [ td [ class "name" ] [ text "7b" ], td [] [ text "read-from-string \"(+ 1 2)\" → ", Fixpoint.Code.inline "[[+ 1 2]]" ] ]
                        , tr [] [ td [ class "name" ] [ text "8-10" ], td [] [ text "load util.shen / id closure / newvar (gensym)" ] ]
                        ]
                    ]
                ]
            }
        ]



-- Primitives


primitivesView : Html Msg
primitivesView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " shen "
                , Fixpoint.Hero.dollar
                , text " ./zinctest globals.csexp"
                , Fixpoint.Hero.blink
                ]
            , title = [ text "Primitives" ]
            , tagline = []
            }
        , Fixpoint.Section.view
            { id = "safe"
            , title = "Type-checked safe wrappers"
            , hint = "// shen/primitives.shen — 37 safe.X wrappers"
            , children =
                [ p []
                    [ text "Each C primitive is wrapped in a "
                    , Fixpoint.Code.inline "safe.X"
                    , text " closure in "
                    , Fixpoint.Code.inline "shen/primitives.shen"
                    , text " that validates its arguments and raises a catchable "
                    , Fixpoint.Code.inline "simple-error"
                    , text " before the raw primitive is called. The C primitives themselves have no runtime type guards — ownership of catchable runtime type errors lives in the safe-wrapper layer."
                    ]
                , Fixpoint.Callout.note
                    [ text "Direct "
                    , code [] [ text "[prim X]" ]
                    , text " dispatch bypasses the safe wrapper (it's the type-safe static path). "
                    , code [] [ text "[global X]" ]
                    , text " → "
                    , code [] [ text "safe.X" ]
                    , text " fires on the dynamic path — a primitive used as a value, higher-order, or explicit "
                    , code [] [ text "(function X)" ]
                    , text "."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "convention"
            , title = "ZINC argument convention"
            , hint = "// the #1 recurring bug pattern"
            , children =
                [ p []
                    [ text "ZINC evaluates arguments "
                    , strong [] [ text "right-to-left" ]
                    , text ": the rightmost arg is pushed first, the leftmost last (on top of the stack). When writing bytecode by hand, push args in right-to-left order:"
                    ]
                , Fixpoint.Code.block
                    [ text "(open \"Makefile\" in) → (s[2:s]in S[8:S]Makefile P[4:s]open)"
                    ]
                , p []
                    [ text "Writing left-to-right works for commutative ops ("
                    , Fixpoint.Code.inline "+"
                    , text ", "
                    , Fixpoint.Code.inline "="
                    , text ", "
                    , Fixpoint.Code.inline "cons-as-pair"
                    , text ") but silently produces wrong results for non-commutative ops ("
                    , Fixpoint.Code.inline "-"
                    , text ", "
                    , Fixpoint.Code.inline "/"
                    , text ", "
                    , Fixpoint.Code.inline "trap-error"
                    , text ", "
                    , Fixpoint.Code.inline "write-byte"
                    , text ")."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "no-push"
            , title = "No push opcode"
            , hint = "// standard ZINC auto-push semantics"
            , children =
                [ p []
                    [ text "All value-producing opcodes (number, string, symbol, boolean, access, global, cur, prim, apply, return) push their result to the stack AND set the accumulator — there is no "
                    , Fixpoint.Code.inline "push"
                    , text " opcode. The compiler relies on auto-push. The "
                    , Fixpoint.Code.inline "pushmark"
                    , text " ("
                    , Fixpoint.Code.inline "m"
                    , text ") opcode remains and is emitted by "
                    , Fixpoint.Code.inline "zinc-c"
                    , text "."
                    ]
                ]
            }
        ]



-- Playground


playgroundView : Html Msg
playgroundView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " shen "
                , Fixpoint.Hero.dollar
                , text " ./zincvm globals.csexp --meta-repl"
                , Fixpoint.Hero.blink
                ]
            , title = [ text "Playground" ]
            , tagline = [ text "the real C VM, compiled to WebAssembly, in your terminal" ]
            }
        , Fixpoint.Section.view
            { id = "playground"
            , title = "A live Shen REPL"
            , hint = "// the zincvm C VM · xterm.js · 100% client-side"
            , children =
                [ p []
                    [ text "This terminal runs the "
                    , strong [] [ text "actual zincvm C VM" ]
                    , text " compiled to WebAssembly — the same interpreter that ships in the repo, booting the ~295-closure "
                    , Fixpoint.Code.inline "globals.csexp"
                    , text " bundle. Type KLambda expressions and hit Enter:"
                    ]
                , Fixpoint.Code.block
                    [ text "(+ 1 2)        → 3\n"
                    , text "(cons 1 2)     → [1 . 2]\n"
                    , text "(= [+ 1 2] [+ 1 2]) → true\n"
                    , text "(hd [1 2 3])   → 1\n"
                    , text "(tl [1 2 3])   → [2 3]\n"
                    , text "(reverse [1 2 3]) → [3 2 1]"
                    ]
                , node "shen-playground" [] []
                , Fixpoint.Callout.note
                    [ text "The playground evaluates primitive calls through the metacircular interpreter. The repo's open "
                    , code [] [ text "close-the-loop" ]
                    , text " item — "
                    , code [] [ text "defun" ]
                    , text " registration and non-bundled closures — is not yet functional in the reduced bundle, so "
                    , code [] [ text "(defun ...)" ]
                    , text " forms report an honest registration result."
                    ]
                , p []
                    [ text "The collector under wasm swaps the native 4 GB mmap reservation for an "
                    , Fixpoint.Code.inline "aligned_alloc"
                    , text " heap, and the input/output bridge is a synchronous "
                    , Fixpoint.Code.inline "shen_eval_line"
                    , text " entrypoint — no blocking "
                    , Fixpoint.Code.inline "fgetc(stdin)"
                    , text ", no web worker."
                    ]
                ]
            }
        ]
