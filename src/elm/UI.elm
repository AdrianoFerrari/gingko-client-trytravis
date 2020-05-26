module UI exposing (countWords, viewConflict, viewFooter, viewHistory, viewSaveIndicator, viewSearchField, viewVideo)

import Coders exposing (treeToMarkdownString)
import Date
import Dict
import Diff exposing (..)
import Html exposing (..)
import Html.Attributes as A exposing (..)
import Html.Events exposing (onClick, onInput)
import List.Extra as ListExtra exposing (getAt)
import Objects
import Octicons as Icon exposing (defaultOptions)
import Regex exposing (Regex, replace)
import Time
import Translation exposing (Language, TranslationId(..), timeDistInWords, tr)
import TreeUtils exposing (..)
import Trees exposing (defaultTree)
import Types exposing (..)


viewSaveIndicator : { m | objects : Objects.Model, dirty : Bool, lastCommitSaved : Maybe Time.Posix, lastFileSaved : Maybe Time.Posix, currentTime : Time.Posix, language : Translation.Language } -> Html Msg
viewSaveIndicator { objects, dirty, lastCommitSaved, lastFileSaved, currentTime, language } =
    let
        lastChangeString =
            timeDistInWords
                language
                (lastCommitSaved |> Maybe.withDefault (Time.millisToPosix 0))
                currentTime

        saveStateSpan =
            if dirty then
                span [ title (tr language LastSaved ++ " " ++ lastChangeString) ] [ text <| tr language UnsavedChanges ]

            else
                case ( lastCommitSaved, lastFileSaved ) of
                    ( Nothing, Nothing ) ->
                        span [] [ text <| tr language NeverSaved ]

                    ( Just commitTime, Nothing ) ->
                        span [ title (tr language LastEdit ++ " " ++ lastChangeString) ] [ text <| tr language SavedInternally ]

                    ( Just commitTime, Just fileTime ) ->
                        span [ title (tr language LastEdit ++ " " ++ lastChangeString) ] [ text <| tr language ChangesSaved ]

                    ( Nothing, Just fileTime ) ->
                        span [ title (tr language LastEdit ++ " " ++ lastChangeString) ] [ text <| tr language DatabaseError ]
    in
    div
        [ id "save-indicator", classList [ ( "inset", True ), ( "saving", dirty ) ] ]
        [ saveStateSpan ]


viewSearchField : { m | viewState : ViewState, language : Language } -> Html Msg
viewSearchField { viewState, language } =
    let
        maybeSearchIcon =
            if viewState.searchField == Nothing then
                Icon.search (defaultOptions |> Icon.color "#445" |> Icon.size 12)

            else
                text ""
    in
    case viewState.viewMode of
        Normal ->
            div
                [ id "search-field" ]
                [ input
                    [ type_ "search"
                    , id "search-input"
                    , required True
                    , title (tr language PressToSearch)
                    , onInput SearchFieldUpdated
                    ]
                    []
                , maybeSearchIcon
                ]

        _ ->
            div
                [ id "search-field" ]
                []


viewFooter : { m | viewState : ViewState, workingTree : Trees.Model, startingWordcount : Int, shortcutTrayOpen : Bool, wordcountTrayOpen : Bool, language : Language, isMac : Bool, textCursorInfo : TextCursorInfo } -> Html Msg
viewFooter model =
    let
        isTextSelected =
            model.textCursorInfo.selected

        wordCounts =
            getWordCounts model

        current =
            wordCounts.document

        session =
            current - model.startingWordcount

        viewWordCount =
            case model.viewState.viewMode of
                Normal ->
                    [ div
                        [ id "wordcount"
                        , classList [ ( "inset", True ), ( "open", model.wordcountTrayOpen ) ]
                        , onClick WordcountTrayToggle
                        ]
                        [ span [] [ text (tr model.language (WordCountSession session)) ]
                        , span [] [ text (tr model.language (WordCountTotal current)) ]
                        , span [] [ text (tr model.language (WordCountCard wordCounts.card)) ]
                        , span [] [ text (tr model.language (WordCountSubtree wordCounts.subtree)) ]
                        , span [] [ text (tr model.language (WordCountGroup wordCounts.group)) ]
                        , span [] [ text (tr model.language (WordCountColumn wordCounts.column)) ]
                        ]
                    ]

                _ ->
                    []

        isOnly =
            case model.workingTree.tree.children of
                Children [ singleRoot ] ->
                    if singleRoot.children == Children [] then
                        True

                    else
                        False

                _ ->
                    False

        hoverHeight n =
            14
                * n
                + 6
                |> Debug.toString
                |> (\s -> s ++ "px")
    in
    div
        [ class "footer" ]
        ([ viewShortcutsToggle model.language model.shortcutTrayOpen model.isMac isOnly model.textCursorInfo model.viewState ]
            ++ viewWordCount
        )


viewHistory : Translation.Language -> String -> Objects.Model -> Html Msg
viewHistory lang currHead objects =
    let
        master =
            Dict.get "heads/master" objects.refs

        historyList =
            case master of
                Just refObj ->
                    (refObj.value :: refObj.ancestors)
                        |> List.reverse

                _ ->
                    []

        maxIdx =
            historyList |> List.length |> (\x -> x - 1) |> Debug.toString

        currIdx =
            historyList
                |> ListExtra.elemIndex currHead
                |> Maybe.map Debug.toString
                |> Maybe.withDefault maxIdx

        checkoutCommit idxStr =
            case String.toInt idxStr of
                Just idx ->
                    case getAt idx historyList of
                        Just commit ->
                            CheckoutCommit commit

                        Nothing ->
                            NoOp

                Nothing ->
                    NoOp
    in
    div [ id "history" ]
        [ input [ type_ "range", A.min "0", A.max maxIdx, value currIdx, step "1", onInput checkoutCommit ] []
        , button [ onClick Restore ] [ text <| tr lang RestoreThisVersion ]
        , button [ onClick CancelHistory ] [ text <| tr lang Cancel ]
        ]


viewVideo : { m | videoModalOpen : Bool } -> Html Msg
viewVideo { videoModalOpen } =
    if videoModalOpen then
        div [ class "modal-container" ]
            [ div [ class "modal" ]
                [ div [ class "modal-header" ]
                    [ h1 [] [ text "Learning Videos" ]
                    , a [ onClick (VideoModal False) ] [ text "×" ]
                    ]
                , iframe
                    [ width 650
                    , height 366
                    , src "https://www.youtube.com/embed/ZOGgwKAU3vg?rel=0&amp;showinfo=0"
                    , attribute "frameborder" "0"
                    , attribute "allowfullscreen" ""
                    ]
                    []
                ]
            ]

    else
        div [] []


viewShortcutsToggle : Language -> Bool -> Bool -> Bool -> TextCursorInfo -> ViewState -> Html Msg
viewShortcutsToggle lang isOpen isMac isOnly textCursorInfo vs =
    let
        isTextSelected =
            textCursorInfo.selected

        viewIf cond content =
            if cond then
                content

            else
                text ""

        spanSplit key descAdd descSplit =
            if textCursorInfo.position == End || textCursorInfo.position == Empty then
                shortcutSpan [ ctrlOrCmd, key ] descAdd

            else
                shortcutSpan [ ctrlOrCmd, key ] descSplit

        splitChild =
            spanSplit "L" (tr lang AddChildAction) (tr lang SplitChildAction)

        splitBelow =
            spanSplit "J" (tr lang AddBelowAction) (tr lang SplitBelowAction)

        splitAbove =
            spanSplit "K" (tr lang AddAboveAction) (tr lang SplitUpwardAction)

        shortcutSpanEnabled enabled keys desc =
            let
                keySpans =
                    keys
                        |> List.map (\k -> span [ class "shortcut-key" ] [ text k ])
            in
            span
                [ classList [ ( "disabled", not enabled ) ] ]
                (keySpans
                    ++ [ text (" " ++ desc) ]
                )

        shortcutSpan =
            shortcutSpanEnabled True

        ctrlOrCmd =
            if isMac then
                "⌘"

            else
                "Ctrl"
    in
    if isOpen then
        let
            iconColor =
                Icon.color "#445"
        in
        case vs.viewMode of
            Normal ->
                div
                    [ id "shortcuts-tray", class "inset", onClick ShortcutTrayToggle ]
                    [ div [ class "popup" ]
                        [ shortcutSpan [ tr lang EnterKey ] (tr lang EnterAction)
                        , viewIf (not isOnly) <| shortcutSpan [ "↑", "↓", "←", "→" ] (tr lang ArrowsAction)
                        , shortcutSpan [ ctrlOrCmd, "→" ] (tr lang AddChildAction)
                        , shortcutSpan [ ctrlOrCmd, "↓" ] (tr lang AddBelowAction)
                        , shortcutSpan [ ctrlOrCmd, "↑" ] (tr lang AddAboveAction)
                        , viewIf (not isOnly) <| shortcutSpan [ "Alt", tr lang ArrowKeys ] (tr lang MoveAction)
                        , viewIf (not isOnly) <| shortcutSpan [ ctrlOrCmd, tr lang Backspace ] (tr lang DeleteAction)
                        , shortcutSpan [ ctrlOrCmd, "Shift", "↓" ] (tr lang MergeDownAction)
                        , shortcutSpan [ ctrlOrCmd, "Shift", "↑" ] (tr lang MergeUpAction)
                        ]
                    , div [ class "icon-stack" ]
                        [ Icon.keyboard (defaultOptions |> iconColor)
                        , Icon.question (defaultOptions |> iconColor |> Icon.size 14)
                        ]
                    ]

            _ ->
                div
                    [ id "shortcuts-tray", class "inset", onClick ShortcutTrayToggle ]
                    [ div [ class "popup" ]
                        [ shortcutSpan [ ctrlOrCmd, tr lang EnterKey ] (tr lang ToSaveChanges)
                        , shortcutSpan [ tr lang EscKey ] (tr lang ToCancelChanges)
                        , splitChild
                        , splitBelow
                        , splitAbove
                        , shortcutSpanEnabled isTextSelected [ ctrlOrCmd, "B" ] (tr lang ForBold)
                        , shortcutSpanEnabled isTextSelected [ ctrlOrCmd, "I" ] (tr lang ForItalic)
                        , span [ class "markdown-guide" ]
                            [ a [ href "http://commonmark.org/help" ]
                                [ text <| tr lang FormattingGuide
                                , span [ class "icon-container" ] [ Icon.linkExternal (defaultOptions |> iconColor |> Icon.size 14) ]
                                ]
                            ]
                        ]
                    , div [ class "icon-stack" ]
                        [ Icon.keyboard (defaultOptions |> iconColor)
                        , Icon.question (defaultOptions |> iconColor |> Icon.size 14)
                        ]
                    ]

    else
        let
            iconColor =
                Icon.color "#6c7c84"
        in
        div
            [ id "shortcuts-tray", class "inset", onClick ShortcutTrayToggle, title <| tr lang KeyboardHelp ]
            [ div [ class "icon-stack" ]
                [ Icon.keyboard (defaultOptions |> iconColor)
                , Icon.question (defaultOptions |> iconColor |> Icon.size 14)
                ]
            ]


viewWordcountProgress : Int -> Int -> Html Msg
viewWordcountProgress current session =
    let
        currW =
            1 / (1 + toFloat session / toFloat current)

        sessW =
            1 - currW
    in
    div [ id "wc-progress" ]
        [ div [ id "wc-progress-wrap" ]
            [ span [ style "flex" (Debug.toString currW), id "wc-progress-bar" ] []
            , span [ style "flex" (Debug.toString sessW), id "wc-progress-bar-session" ] []
            ]
        ]


getWordCounts : { m | viewState : ViewState, workingTree : Trees.Model } -> WordCount
getWordCounts model =
    let
        activeCardId =
            model.viewState.active

        tree =
            model.workingTree.tree

        currentTree =
            getTree activeCardId tree
                |> Maybe.withDefault defaultTree

        currentGroup =
            getSiblings activeCardId tree

        cardCount =
            countWords currentTree.content

        subtreeCount =
            cardCount + countWords (treeToMarkdownString False currentTree)

        groupCount =
            currentGroup
                |> List.map .content
                |> String.join "\n\n"
                |> countWords

        columnCount =
            getColumn (getDepth 0 tree activeCardId) tree
                -- Maybe (List (List Tree))
                |> Maybe.withDefault [ [] ]
                |> List.concat
                |> List.map .content
                |> String.join "\n\n"
                |> countWords

        treeCount =
            countWords (treeToMarkdownString False tree)
    in
    WordCount
        cardCount
        subtreeCount
        groupCount
        columnCount
        treeCount


countWords : String -> Int
countWords str =
    let
        punctuation =
            Regex.fromString "[!@#$%^&*():;\"',.]+"
                |> Maybe.withDefault Regex.never
    in
    str
        |> String.toLower
        |> replace punctuation (\_ -> "")
        |> String.words
        |> List.filter ((/=) "")
        |> List.length


viewConflict : Conflict -> Html Msg
viewConflict { id, opA, opB, selection, resolved } =
    let
        withManual cardId oursElement theirsElement =
            li
                []
                [ fieldset []
                    [ radio (SetSelection id Original cardId) (selection == Original) (text "Original")
                    , radio (SetSelection id Ours cardId) (selection == Ours) oursElement
                    , radio (SetSelection id Theirs cardId) (selection == Theirs) theirsElement
                    , radio (SetSelection id Manual cardId) (selection == Manual) (text "Merged")
                    , label []
                        [ input [ checked resolved, type_ "checkbox", onClick (Resolve id) ] []
                        , text "Resolved"
                        ]
                    ]
                ]

        withoutManual cardIdA cardIdB =
            li
                []
                [ fieldset []
                    [ radio (SetSelection id Original "") (selection == Original) (text "Original")
                    , radio (SetSelection id Ours cardIdA) (selection == Ours) (text ("Ours:" ++ (Debug.toString opA |> String.left 3)))
                    , radio (SetSelection id Theirs cardIdB) (selection == Theirs) (text ("Theirs:" ++ (Debug.toString opB |> String.left 3)))
                    , label []
                        [ input [ checked resolved, type_ "checkbox", onClick (Resolve id) ] []
                        , text "Resolved"
                        ]
                    ]
                ]

        newConflictView cardId ourChanges theirChanges =
            div [ class "flex-row" ]
                [ div [ class "conflict-container flex-column" ]
                    [ div
                        [ classList [ ( "row option", True ), ( "selected", selection == Original ) ]
                        , onClick (SetSelection id Original cardId)
                        ]
                        [ text "Original" ]
                    , div [ class "row flex-row" ]
                        [ div
                            [ classList [ ( "option", True ), ( "selected", selection == Ours ) ]
                            , onClick (SetSelection id Ours cardId)
                            ]
                            [ text "Ours"
                            , ul [ class "changelist" ] ourChanges
                            ]
                        , div
                            [ classList [ ( "option", True ), ( "selected", selection == Theirs ) ]
                            , onClick (SetSelection id Theirs cardId)
                            ]
                            [ text "Theirs"
                            , ul [ class "changelist" ] theirChanges
                            ]
                        ]
                    , div
                        [ classList [ ( "row option", True ), ( "selected", selection == Manual ) ]
                        , onClick (SetSelection id Manual cardId)
                        ]
                        [ text "Merged" ]
                    ]
                , button [ onClick (Resolve id) ] [ text "Resolved" ]
                ]
    in
    case ( opA, opB ) of
        ( Mod idA _ strA orig, Mod _ _ strB _ ) ->
            let
                diffLinesString l r =
                    diffLines l r
                        |> List.filterMap
                            (\c ->
                                case c of
                                    NoChange s ->
                                        Nothing

                                    Added s ->
                                        Just (li [] [ ins [ class "diff" ] [ text s ] ])

                                    Removed s ->
                                        Just (li [] [ del [ class "diff" ] [ text s ] ])
                            )
            in
            newConflictView idA [] []

        ( Types.Ins idA _ _ _, Del idB _ ) ->
            withoutManual idA idB

        ( Del idA _, Types.Ins idB _ _ _ ) ->
            withoutManual idA idB

        _ ->
            withoutManual "" ""


radio : msg -> Bool -> Html msg -> Html msg
radio msg bool labelElement =
    label []
        [ input [ type_ "radio", checked bool, onClick msg ] []
        , labelElement
        ]
