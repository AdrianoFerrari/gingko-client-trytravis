module Coders exposing (collabStateDecoder, collabStateToValue, conflictDecoder, conflictToValue, exportSettingsDecoder, fontSettingsEncoder, lazyRecurse, maybeToValue, modeDecoder, modeToValue, opDecoder, opToValue, selectionDecoder, selectionToValue, statusDecoder, statusToValue, textCursorInfoDecoder, treeDecoder, treeListDecoder, treeToJSON, treeToJSONrecurse, treeToMarkdown, treeToMarkdownRecurse, treeToMarkdownString, treeToValue, treesModelDecoder, tripleDecoder, tupleDecoder, tupleToValue)

import Fonts
import Json.Decode as Json exposing (..)
import Json.Encode as Enc
import Trees
import Types exposing (..)



-- Tree


treeToValue : Tree -> Enc.Value
treeToValue tree =
    case tree.children of
        Children c ->
            Enc.object
                [ ( "id", Enc.string tree.id )
                , ( "content", Enc.string tree.content )
                , ( "children", Enc.list treeToValue c )
                ]


treesModelDecoder : Decoder Trees.Model
treesModelDecoder =
    Json.map2 Trees.Model
        treeDecoder
        (succeed [])


treeDecoder : Decoder Tree
treeDecoder =
    Json.map3 Tree
        (field "id" string)
        (field "content" string)
        (oneOf
            [ field
                "children"
                (list (lazyRecurse (\_ -> treeDecoder))
                    |> Json.map Children
                )
            , succeed (Children [])
            ]
        )


treeListDecoder : Decoder (List ( String, String ))
treeListDecoder =
    list (tupleDecoder string string)



-- ViewState


collabStateToValue : CollabState -> Enc.Value
collabStateToValue collabState =
    Enc.object
        [ ( "uid", Enc.string collabState.uid )
        , ( "mode", modeToValue collabState.mode )
        , ( "field", Enc.string collabState.field )
        ]


collabStateDecoder : Decoder CollabState
collabStateDecoder =
    Json.map3 CollabState
        (field "uid" string)
        (field "mode" modeDecoder)
        (field "field" string)



-- Mode


modeToValue : Mode -> Enc.Value
modeToValue mode =
    case mode of
        CollabActive id ->
            tupleToValue Enc.string ( "CollabActive", id )

        CollabEditing id ->
            tupleToValue Enc.string ( "CollabEditing", id )


modeDecoder : Decoder Mode
modeDecoder =
    let
        modeHelp : ( String, String ) -> Decoder Mode
        modeHelp ( tag, idIn ) =
            case ( tag, idIn ) of
                ( "CollabActive", id ) ->
                    succeed (CollabActive id)

                ( "CollabEditing", id ) ->
                    succeed (CollabEditing id)

                _ ->
                    fail <| "Failed mode decoder"
    in
    tupleDecoder string string
        |> andThen modeHelp



-- Status


statusToValue : Status -> Enc.Value
statusToValue status =
    case status of
        Clean head ->
            Enc.object
                [ ( "_id", "status" |> Enc.string )
                , ( "status", "clean" |> Enc.string )
                , ( "head", head |> Enc.string )
                ]

        MergeConflict tree aSha bSha conflicts ->
            Enc.object
                [ ( "_id", "status" |> Enc.string )
                , ( "status", "merge-conflict" |> Enc.string )
                , ( "tree", tree |> treeToValue )
                , ( "aSha", aSha |> Enc.string )
                , ( "bSha", bSha |> Enc.string )
                , ( "conflicts", Enc.list conflictToValue conflicts )
                ]

        Bare ->
            Enc.object
                [ ( "_id", "status" |> Enc.string )
                , ( "status", "bare" |> Enc.string )
                , ( "bare", Enc.bool True )
                ]


statusDecoder : Decoder Status
statusDecoder =
    let
        cleanDecoder =
            Json.map (\h -> Clean h)
                (field "head" string)

        mergeConflictDecoder =
            Json.map4 (\t a b c -> MergeConflict t a b c)
                (field "tree" treeDecoder)
                (field "aSha" string)
                (field "bSha" string)
                (field "conflicts" (list conflictDecoder))

        bareDecoder =
            Json.map (\_ -> Bare)
                (field "bare" bool)
    in
    oneOf
        [ cleanDecoder
        , mergeConflictDecoder
        , bareDecoder
        ]



-- Conflict


conflictToValue : Conflict -> Enc.Value
conflictToValue { id, opA, opB, selection, resolved } =
    Enc.object
        [ ( "id", Enc.string id )
        , ( "opA", opToValue opA )
        , ( "opB", opToValue opB )
        , ( "selection", selectionToValue selection )
        , ( "resolved", Enc.bool resolved )
        ]


conflictDecoder : Decoder Conflict
conflictDecoder =
    Json.map5 Conflict
        (field "id" string)
        (field "opA" opDecoder)
        (field "opB" opDecoder)
        (field "selection" selectionDecoder)
        (field "resolved" bool)



-- Op


opToValue : Op -> Enc.Value
opToValue op =
    case op of
        Mod id parents str orig ->
            Enc.list
                Enc.string
                ([ "mod", id, str, orig ] ++ parents)

        Del id parents ->
            Enc.list
                Enc.string
                ([ "del", id ] ++ parents)

        _ ->
            Enc.null


opDecoder : Decoder Op
opDecoder =
    let
        modDecoder =
            Json.map4 (\id str orig parents -> Mod id parents str orig)
                (index 1 string)
                (index 2 string)
                (index 3 string)
                (index 4 (list string))

        delDecoder =
            Json.map2 (\id parents -> Del id parents)
                (index 1 string)
                (index 2 (list string))
    in
    oneOf
        [ modDecoder
        , delDecoder
        ]



-- Selection


selectionToValue : Selection -> Enc.Value
selectionToValue selection =
    case selection of
        Ours ->
            "ours" |> Enc.string

        Theirs ->
            "theirs" |> Enc.string

        Original ->
            "original" |> Enc.string

        Manual ->
            "manual" |> Enc.string


selectionDecoder : Decoder Selection
selectionDecoder =
    let
        fn s =
            case s of
                "ours" ->
                    Ours

                "theirs" ->
                    Theirs

                "original" ->
                    Original

                "manual" ->
                    Manual

                _ ->
                    Manual
    in
    Json.map fn string



-- Text Cursor


cursorPositionDecoder : Decoder CursorPosition
cursorPositionDecoder =
    Json.map
        (\s ->
            case s of
                "start" ->
                    Start

                "end" ->
                    End

                "other" ->
                    Other

                _ ->
                    Other
        )
        string


textCursorInfoDecoder : Decoder TextCursorInfo
textCursorInfoDecoder =
    Json.map3 TextCursorInfo
        (field "selected" bool)
        (field "position" cursorPositionDecoder)
        (field "text" (tupleDecoder string string))



-- EXPORT ENCODINGS


exportSettingsDecoder : Decoder ExportSettings
exportSettingsDecoder =
    let
        formatFromString s =
            case s of
                "json" ->
                    JSON

                "txt" ->
                    TXT

                "docx" ->
                    DOCX

                _ ->
                    JSON

        formatDecoder =
            Json.map formatFromString string

        exportStringDecoder =
            Json.map
                (\s ->
                    case s of
                        "all" ->
                            All

                        "current" ->
                            CurrentSubtree

                        _ ->
                            All
                )
                string

        exportColumnDecoder =
            Json.map
                (\i -> ColumnNumber i)
                (field "column" int)

        exportSelectionDecoder =
            oneOf
                [ exportStringDecoder
                , exportColumnDecoder
                ]

        exportFilepathDecoder =
            Json.maybe string
    in
    Json.map3 ExportSettings
        (field "format" formatDecoder)
        (field "selection" exportSelectionDecoder)
        (field "filepath" exportFilepathDecoder)


treeToJSON : Tree -> Enc.Value
treeToJSON tree =
    case tree.children of
        Children c ->
            Enc.list treeToJSONrecurse c


treeToJSONrecurse : Tree -> Enc.Value
treeToJSONrecurse tree =
    case tree.children of
        Children c ->
            Enc.object
                [ ( "content", Enc.string tree.content )
                , ( "children", Enc.list treeToJSONrecurse c )
                ]


treeToMarkdown : Bool -> Tree -> Enc.Value
treeToMarkdown withRoot tree =
    tree
        |> treeToMarkdownString withRoot
        |> Enc.string


treeToMarkdownString : Bool -> Tree -> String
treeToMarkdownString withRoot tree =
    let
        contentList =
            case tree.children of
                Children c ->
                    List.map treeToMarkdownRecurse c
    in
    if withRoot then
        tree.content
            :: contentList
            |> String.join "\n\n"

    else
        contentList
            |> String.join "\n\n"


treeToMarkdownRecurse : Tree -> String
treeToMarkdownRecurse tree =
    case tree.children of
        Children c ->
            [ tree.content ]
                ++ List.map treeToMarkdownRecurse c
                |> String.join "\n\n"



-- FONT SETTINGS


fontSettingsEncoder : Fonts.Settings -> Enc.Value
fontSettingsEncoder { heading, content, monospace } =
    Enc.list Enc.string [ heading, content, monospace ]



-- HELPERS


lazyRecurse : (() -> Decoder a) -> Decoder a
lazyRecurse thunk =
    let
        toResult =
            \js -> decodeValue (thunk ()) js
    in
    andThen
        (\a ->
            case toResult a of
                Ok b ->
                    succeed b

                Err err ->
                    fail (errorToString err)
        )
        value


maybeToValue : (a -> Enc.Value) -> Maybe a -> Enc.Value
maybeToValue encoder mb =
    case mb of
        Nothing ->
            Enc.null

        Just v ->
            encoder v


tupleToValue : (a -> Enc.Value) -> ( a, a ) -> Enc.Value
tupleToValue encoder ( aVal, bVal ) =
    Enc.list encoder [ aVal, bVal ]


tupleDecoder : Decoder a -> Decoder b -> Decoder ( a, b )
tupleDecoder a b =
    index 0 a
        |> andThen
            (\aVal ->
                index 1 b
                    |> andThen (\bVal -> succeed ( aVal, bVal ))
            )


tripleDecoder : Decoder a -> Decoder b -> Decoder c -> Decoder ( a, b, c )
tripleDecoder a b c =
    index 0 a
        |> andThen
            (\aVal ->
                index 1 b
                    |> andThen
                        (\bVal ->
                            index 2 c
                                |> andThen (\cVal -> succeed ( aVal, bVal, cVal ))
                        )
            )
