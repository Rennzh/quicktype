module CSharp 
    ( renderer
    ) where

import Doc
import IRGraph
import Prelude
import Types

import Data.Char.Unicode (GeneralCategory(..), generalCategory, isLetter)
import Data.Foldable (find, for_, intercalate)
import Data.List (List, (:))
import Data.List as L
import Data.Map (Map)
import Data.Map as M
import Data.Maybe (Maybe(..), isNothing)
import Data.Set (Set)
import Data.Set as S
import Data.String as Str
import Data.String.Util (capitalize, camelCase, stringEscape)
import Data.Tuple (Tuple(..))
import Partial.Unsafe (unsafePartial)

import Utils (removeElement)

type CSDoc = Doc Unit

forbiddenNames :: Array String
forbiddenNames = [ "Converter", "JsonConverter", "Type" ]

renderer :: Renderer
renderer =
    { name: "C#"
    , aceMode: "csharp"
    , extension: "cs"
    , render: renderGraphToCSharp
    }

renderGraphToCSharp :: IRGraph -> String
renderGraphToCSharp graph =
    runDoc csharpDoc nameForClass unionName unionPredicate nextNameToTry (S.fromFoldable forbiddenNames) graph unit
    where
        unionPredicate =
            case _ of
            IRUnion ur ->
                let s = unionToSet ur
                in
                    if isNothing $ nullableFromSet s then
                        Just s
                    else
                        Nothing
            _ -> Nothing
        nameForClass (IRClassData { names }) =
            csNameStyle $ combineNames names
        nextNameToTry s =
            "Other" <> s

unionName :: List String -> String
unionName s =
    s
    # L.sort
    <#> csNameStyle
    # intercalate "Or"

isValueType :: IRType -> Boolean
isValueType IRInteger = true
isValueType IRDouble = true
isValueType IRBool = true
isValueType _ = false

isLetterCharacter :: Char -> Boolean
isLetterCharacter c =
    isLetter c || (generalCategory c == Just LetterNumber)

isStartCharacter :: Char -> Boolean
isStartCharacter c =
    isLetterCharacter c || c == '_'

isPartCharacter :: Char -> Boolean
isPartCharacter c =
    case generalCategory c of
    Nothing -> false
    Just DecimalNumber -> true
    Just ConnectorPunctuation -> true
    Just NonSpacingMark -> true
    Just SpacingCombiningMark -> true
    Just Format -> true
    _ -> isLetterCharacter c

legalizeIdentifier :: String -> String
legalizeIdentifier str =
    case Str.charAt 0 str of
    -- FIXME: use the type to infer a name?
    Nothing -> "Empty"
    Just s ->
        if isStartCharacter s then
            Str.fromCharArray $ map (\c -> if isLetterCharacter c then c else '_') $ Str.toCharArray str
        else
            legalizeIdentifier ("_" <> str)

nullableFromSet :: Set IRType -> Maybe IRType
nullableFromSet s =
    case L.fromFoldable s of
    IRNull : x : L.Nil -> Just x
    x : IRNull : L.Nil -> Just x
    _ -> Nothing

renderUnionToCSharp :: Set IRType -> CSDoc String
renderUnionToCSharp s =
    case nullableFromSet s of
    Just x -> do
        rendered <- renderTypeToCSharp x
        pure if isValueType x then rendered <> "?" else rendered
    Nothing -> lookupUnionName s

lookupUnionName :: Set IRType -> CSDoc String
lookupUnionName s = do
    unionNames <- getUnionNames
    pure $ lookupName s unionNames

renderTypeToCSharp :: IRType -> CSDoc String
renderTypeToCSharp = case _ of
    IRNothing -> pure "object"
    IRNull -> pure "object"
    IRInteger -> pure "int"
    IRDouble -> pure "double"
    IRBool -> pure "bool"
    IRString -> pure "string"
    IRArray a -> do
        rendered <- renderTypeToCSharp a
        pure $ rendered <> "[]"
    IRClass i -> lookupClassName i
    IRMap t -> do
        rendered <- renderTypeToCSharp t
        pure $ "Dictionary<string, " <> rendered <> ">"
    IRUnion types -> renderUnionToCSharp $ unionToSet types

csNameStyle :: String -> String
csNameStyle = camelCase >>> capitalize >>> legalizeIdentifier

csharpDoc :: CSDoc Unit
csharpDoc = do
    lines """// To parse this JSON data, add NuGet 'Newtonsoft.Json' then do:
             //
             //   var data = QuickType.Converter.FromJson(jsonString);
             //
             namespace QuickType
             {"""
    blank
    indent do
        lines """using System;
                 using System.Net;
                 using System.Collections.Generic;

                 using Newtonsoft.Json;"""
        blank
        renderJsonConverter
        blank
        classes <- getClasses
        for_ classes \(Tuple i cd) -> do
            className <- lookupClassName i
            renderCSharpClass cd className
            blank
        unions <- getUnions
        for_ unions \types -> do
            renderCSharpUnion types
            blank
    lines "}"

stringIfTrue :: Boolean -> String -> String
stringIfTrue true s = s
stringIfTrue false _ = ""

renderJsonConverter :: CSDoc Unit
renderJsonConverter = do
    unionNames <- getUnionNames
    let haveUnions = not $ M.isEmpty unionNames
    let names = M.values unionNames
    lines $ "public class Converter" <> stringIfTrue haveUnions " : JsonConverter" <> " {"
    indent do
        IRGraph { toplevel } <- getGraph
        toplevelType <- renderTypeToCSharp toplevel
        lines "// Loading helpers"
        let converterParam = stringIfTrue haveUnions ", new Converter()"
        lines
            $ "public static "
            <> toplevelType
            <> " FromJson(string json) => JsonConvert.DeserializeObject<"
            <> toplevelType
            <> ">(json"
            <> converterParam
            <> ");"

        when haveUnions do
            blank
            lines "public override bool CanConvert(Type t) {"
            indent $ lines $ "return " <> intercalate " || " (map (\n -> "t == typeof(" <> n <> ")") names) <> ";"
            lines "}"
            blank
            lines "public override object ReadJson(JsonReader reader, Type t, object existingValue, JsonSerializer serializer) {"
            indent do
                -- FIXME: call the constructor via reflection?
                for_ names \name -> do
                    lines $ "if (t == typeof(" <> name <> "))"
                    indent $ lines $ "return new " <> name <> "(reader, serializer);"
                lines "throw new Exception(\"Unknown type\");"
            lines "}"
            blank
            lines "public override void WriteJson(JsonWriter writer, object value, JsonSerializer serializer) {"
            indent $ lines "throw new NotImplementedException();"
            lines "}"
            blank
            lines "public override bool CanWrite { get { return false; } }"
    lines "}"

tokenCase :: String -> CSDoc Unit
tokenCase tokenType =
    lines $ "case JsonToken." <> tokenType <> ":"

renderNullDeserializer :: Set IRType -> CSDoc Unit
renderNullDeserializer types =
    when (S.member IRNull types) do
        tokenCase "Null"
        indent do
            lines "break;"

unionFieldName :: IRType -> CSDoc String
unionFieldName t = do
    graph <- getGraph
    let typeName = typeNameForUnion graph t
    pure $ csNameStyle typeName

deserialize :: String -> String -> CSDoc Unit
deserialize fieldName typeName = do
    lines $ fieldName <> " = serializer.Deserialize<" <> typeName <> ">(reader);"
    lines "break;"

deserializeType :: IRType -> CSDoc Unit
deserializeType t = do
    fieldName <- unionFieldName t
    renderedType <- renderTypeToCSharp t
    deserialize fieldName renderedType

renderPrimitiveDeserializer :: List String -> IRType -> Set IRType -> CSDoc Unit
renderPrimitiveDeserializer tokenTypes t types =
    when (S.member t types) do
        for_ tokenTypes \tokenType -> do
            tokenCase tokenType
        indent do
            deserializeType t

renderDoubleDeserializer :: Set IRType -> CSDoc Unit
renderDoubleDeserializer types =
    when (S.member IRDouble types) do
        unless (S.member IRInteger types) do
            tokenCase "Integer"
        tokenCase "Float"
        indent do
            deserializeType IRDouble

renderGenericDeserializer :: (IRType -> Boolean) -> String -> Set IRType -> CSDoc Unit
renderGenericDeserializer predicate tokenType types = unsafePartial $
    case find predicate types of
    Nothing -> pure unit
    Just t -> do
        tokenCase tokenType
        indent do
            deserializeType t

renderCSharpUnion :: Set IRType -> CSDoc Unit
renderCSharpUnion allTypes = do
    name <- lookupUnionName allTypes
    let { element: emptyOrNull, rest: nonNullTypes } = removeElement (_ == IRNull) allTypes
    graph <- getGraph
    line $ words ["public struct", name, "{"]
    indent do
        for_ nonNullTypes \t -> do
            typeString <- renderUnionToCSharp $ S.union (S.singleton t) (S.singleton IRNull)
            field <- unionFieldName t
            lines $ "public " <> typeString <> " " <> field <> ";"
        blank
        lines $ "public " <> name <> "(JsonReader reader, JsonSerializer serializer) {"
        indent do
            for_ (L.fromFoldable nonNullTypes) \field -> do
                fieldName <- unionFieldName field
                lines $ fieldName <> " = null;"
            lines "switch (reader.TokenType) {"
            indent do
                renderNullDeserializer allTypes
                renderPrimitiveDeserializer (L.singleton "Integer") IRInteger allTypes
                renderDoubleDeserializer allTypes
                renderPrimitiveDeserializer (L.singleton "Boolean") IRBool allTypes
                renderPrimitiveDeserializer ("String" : "Date" : L.Nil) IRString allTypes
                renderGenericDeserializer isArray "StartArray" allTypes
                renderGenericDeserializer isClass "StartObject" allTypes
                renderGenericDeserializer isMap "StartObject" allTypes
                lines $ "default: throw new Exception(\"Cannot convert " <> name <> "\");"
            lines "}"
        lines "}"
    lines "}"

renderCSharpClass :: IRClassData -> String -> CSDoc Unit
renderCSharpClass (IRClassData { names, properties }) className = do
    let propertyNames = transformNames csNameStyle ("Other" <> _) (S.singleton className) $ map (\n -> Tuple n n) $ M.keys properties
    line $ words ["public class", className]

    lines "{"
    indent do
        for_ (M.toUnfoldable properties :: Array _) \(Tuple pname ptype) -> do
            line do
                string "[JsonProperty(\""
                string $ stringEscape pname
                string "\")]"
            line do
                string "public "
                rendered <- renderTypeToCSharp ptype
                string rendered
                let csPropName = lookupName pname propertyNames
                words ["", csPropName, "{ get; set; }"]
            blank
    lines "}"
