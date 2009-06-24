-----------------------------------------------------------------------
--                               G N A T C O L L                     --
--                                                                   --
--                 Copyright (C) 2005-2009, AdaCore                  --
--                                                                   --
-- GPS is free  software;  you can redistribute it and/or modify  it --
-- under the terms of the GNU General Public License as published by --
-- the Free Software Foundation; either version 2 of the License, or --
-- (at your option) any later version.                               --
--                                                                   --
-- This program is  distributed in the hope that it will be  useful, --
-- but  WITHOUT ANY WARRANTY;  without even the  implied warranty of --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU --
-- General Public License for more details. You should have received --
-- a copy of the GNU General Public License along with this program; --
-- if not,  write to the  Free Software Foundation, Inc.,  59 Temple --
-- Place - Suite 330, Boston, MA 02111-1307, USA.                    --
-----------------------------------------------------------------------

with Ada.Calendar;               use Ada.Calendar;
with Ada.Calendar.Time_Zones;    use Ada.Calendar.Time_Zones;
with Ada.Containers;             use Ada.Containers;
with Ada.Strings.Fixed;          use Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with GNAT.Calendar.Time_IO;      use GNAT.Calendar.Time_IO;
with GNAT.Strings;               use GNAT.Strings;
with GNATCOLL.Utils;             use GNATCOLL.Utils;

package body GNATCOLL.SQL is

   use Table_List, Field_List, Criteria_List, Table_Sets;
   use When_Lists;
   use type Boolean_Fields.Field;

   Comparison_Like        : aliased constant String := " LIKE ";
   Comparison_ILike       : aliased constant String := " ILIKE ";
   Comparison_Not_Like    : aliased constant String := " NOT LIKE ";
   Comparison_Not_ILike   : aliased constant String := " NOT ILIKE ";
   Comparison_Overlaps    : aliased constant String := " OVERLAPS ";
   Comparison_Any         : aliased constant String := " = ANY (";
   Comparison_Parenthesis : aliased constant String := ")";

   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (SQL_Table'Class, SQL_Table_Access);

   function Combine
     (Left, Right : SQL_Criteria; Op : SQL_Criteria_Type) return SQL_Criteria;
   --  Combine the two criterias with a specific operator.

   procedure Append_Tables
     (From : SQL_Field_List; To : in out Table_Sets.Set);
   --  Append all tables referenced in From to To.

   function To_String (Names : Table_Names) return String;
   function To_String (Self : Table_Sets.Set) return Unbounded_String;
   --  Various implementations for To_String, for different types

   function Clone_Select_Contents
     (Query : SQL_Query) return Query_Select_Contents_Access;
   --  Clone the contents of the query (assuming it is a SELECT query)

   package Any_Fields is new Data_Fields (SQL_Field);
   type SQL_Field_Any is new Any_Fields.Field with null record;

   -------------------
   -- As field data --
   -------------------
   --  Used when a field is renamed via "anything AS name"

   type As_Field_Internal is new SQL_Field_Internal with record
      As      : GNAT.Strings.String_Access;
      Renamed : SQL_Field_Pointer;
   end record;
   type As_Field_Internal_Access is access all As_Field_Internal'Class;
   overriding procedure Free (Self : in out As_Field_Internal);
   overriding function To_String
     (Self : As_Field_Internal; Long : Boolean) return String;
   overriding procedure Append_Tables
     (Self : As_Field_Internal; To : in out Table_Sets.Set);
   overriding procedure Append_If_Not_Aggregate
     (Self         : access As_Field_Internal;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean);

   --------------------------
   -- Multiple args fields --
   --------------------------
   --  Several fields grouped into one via functions, operators or other. Such
   --  fields are not typed ("field1 operator field2 operator field3 ...")

   type Multiple_Args_Field_Internal is new SQL_Field_Internal with record
      Func_Name      : GNAT.Strings.String_Access; --  can be null
      Separator      : GNAT.Strings.String_Access;
      Suffix         : GNAT.Strings.String_Access; --  can be null
      List           : Field_List.List;
   end record;
   type Multiple_Args_Field_Internal_Access is access all
     Multiple_Args_Field_Internal'Class;
   overriding function To_String
     (Self : Multiple_Args_Field_Internal; Long : Boolean) return String;
   overriding procedure Append_Tables
     (Self : Multiple_Args_Field_Internal; To : in out Table_Sets.Set);
   overriding procedure Append_If_Not_Aggregate
     (Self         : access Multiple_Args_Field_Internal;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean);
   overriding procedure Free (Self : in out Multiple_Args_Field_Internal);

   -----------------------
   -- Aggregrate fields --
   -----------------------
   --  Representing an sql aggregate function

   type Aggregate_Field_Internal is new SQL_Field_Internal with record
      Func     : GNAT.Strings.String_Access;
      Params   : SQL_Field_List;
      Criteria : SQL_Criteria;
   end record;
   type Aggregate_Field_Internal_Access
     is access all Aggregate_Field_Internal'Class;
   overriding procedure Free (Self : in out Aggregate_Field_Internal);
   overriding function To_String
     (Self : Aggregate_Field_Internal; Long : Boolean) return String;
   overriding procedure Append_Tables
     (Self : Aggregate_Field_Internal; To : in out Table_Sets.Set);
   overriding procedure Append_If_Not_Aggregate
     (Self         : access Aggregate_Field_Internal;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean);

   -----------------
   -- Sort fields --
   -----------------
   --  Fields used in the "ORDER BY" clauses

   type Sorted_Field_Internal is new SQL_Field_Internal with record
      Ascending : Boolean;
      Sorted    : SQL_Field_Pointer;
   end record;
   type Sorted_Field_Internal_Access is access all Sorted_Field_Internal'Class;
   overriding function To_String
     (Self : Sorted_Field_Internal; Long : Boolean) return String;
   overriding procedure Append_Tables
     (Self : Sorted_Field_Internal; To : in out Table_Sets.Set);
   overriding procedure Append_If_Not_Aggregate
     (Self         : access Sorted_Field_Internal;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean);

   -------------------------
   -- Field_List_Function --
   -------------------------

   function Field_List_Function
     (Fields : SQL_Field_List) return SQL_Field'Class
   is
      Data   : constant Multiple_Args_Field_Internal_Access :=
        new Multiple_Args_Field_Internal;
      F : SQL_Field_Any (Table => null, Instance => null, Name => null);
      C : Field_List.Cursor := First (Fields);
   begin
      if Func_Name /= "" then
         Data.Func_Name := new String'(Func_Name);
      end if;

      Data.Separator := new String'(Separator);

      if Suffix /= "" then
         Data.Suffix := new String'(Suffix);
      end if;

      while Has_Element (C) loop
         declare
            Field    : constant SQL_Field'Class := Element (C);
            Internal : SQL_Field_Internal_Access;
            D        : Multiple_Args_Field_Internal_Access;
            C2       : Field_List.Cursor;
         begin
            if Field in SQL_Field_Any'Class then
               Internal := SQL_Field_Any (Field).Data.Data;
               if Internal.all in Multiple_Args_Field_Internal'Class then
                  D := Multiple_Args_Field_Internal_Access (Internal);

                  if D.Separator.all = Separator then
                     --  Avoid nested concatenations, put them all at the same
                     --  level. This simplifies the query. Due to this, we are
                     --  also sure the concatenation itself doesn't have
                     --  sub-expressions

                     C2 := First (D.List);
                     while Has_Element (C2) loop
                        Append (Data.List, Element (C2));
                        Next (C2);
                     end loop;
                  else
                     Append (Data.List, Field);
                  end if;
               else
                  Append (Data.List, Field);
               end if;
            else
               Append (Data.List, Field);
            end if;
         end;
         Next (C);
      end loop;

      F.Data.Data := SQL_Field_Internal_Access (Data);
      return F;
   end Field_List_Function;

   ----------------------
   -- Normalize_String --
   ----------------------

   function Normalize_String (Str : String) return String
   is
      Num_Of_Apostrophes : constant Natural :=
        Ada.Strings.Fixed.Count (Str, "'");
      Num_Of_Backslashes : constant Natural :=
        Ada.Strings.Fixed.Count (Str, "\");
      New_Str            : String
        (Str'First .. Str'Last + Num_Of_Apostrophes + Num_Of_Backslashes);
      Index              : Natural := Str'First;
      Prepend_E          : Boolean := False;
   begin
      if Num_Of_Apostrophes = 0
        and then Num_Of_Backslashes = 0
      then
         return "'" & Str & "'";
      end if;

      for I in Str'Range loop
         if Str (I) = ''' then
            New_Str (Index .. Index + 1) := "''";
            Index := Index + 1;
         elsif Str (I) = '\' then
            New_Str (Index .. Index + 1) := "\\";
            Prepend_E := True;
            Index := Index + 1;
         else
            New_Str (Index) := Str (I);
         end if;
         Index := Index + 1;
      end loop;

      if Prepend_E then
         return "E'" & New_Str & "'";
      else
         return "'" & New_Str & "'";
      end if;
   end Normalize_String;

   --------
   -- FK --
   --------

   function FK
     (Self : SQL_Table; Foreign : SQL_Table'Class) return SQL_Criteria
   is
      pragma Unreferenced (Self, Foreign);
   begin
      return No_Criteria;
   end FK;

   ---------------
   -- To_String --
   ---------------

   function To_String (Self : SQL_Left_Join_Table) return String is
      Result : Unbounded_String;
      C      : Table_List.Cursor := Table_List.No_Element;
   begin
      if Self.Data.Data /= null then
         C := First (Self.Data.Data.Tables.Data.Data.List);
      end if;

      Append (Result, "(");
      Append (Result, To_String (Element (C)));
      if Self.Data.Data.Is_Left_Join then
         Append (Result, " LEFT JOIN ");
      else
         Append (Result, " JOIN ");
      end if;
      Next (C);
      Append (Result, To_String (Element (C)));
      if Self.Data.Data.On /= No_Criteria then
         Append (Result, " ON ");
         Append
           (Result,
            GNATCOLL.SQL_Impl.To_String (Self.Data.Data.On, Long => True));
      end if;
      Append (Result, ")");

      if Self.Instance /= null then
         Append (Result, " " & Self.Instance.all);
      end if;
      return To_String (Result);
   end To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String (Self : Subquery_Table) return String is
   begin
      if Self.Instance /= null then
         return "(" & To_String (To_String (Self.Query)) & ") "
           & Self.Instance.all;
      else
         return "(" & To_String (To_String (Self.Query)) & ")";
      end if;
   end To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String (Self : SQL_Table) return String is
   begin
      if Self.Instance = null then
         return Self.Table_Name.all;
      else
         return Self.Table_Name.all & " " & Self.Instance.all;
      end if;
   end To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String (Self : SQL_Table_List) return String is
      C      : Table_List.Cursor := Table_List.No_Element;
      Result : Unbounded_String;
   begin
      if Self.Data.Data /= null then
         C := First (Self.Data.Data.List);
      end if;

      if Has_Element (C) then
         Append (Result, To_String (Element (C)));
         Next (C);
      end if;

      while Has_Element (C) loop
         Append (Result, ", ");
         Append (Result, To_String (Element (C)));
         Next (C);
      end loop;

      return To_String (Result);
   end To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String (Names : Table_Names) return String is
   begin
      if Names.Instance = null then
         return Names.Name.all;
      else
         return Names.Name.all & " " & Names.Instance.all;
      end if;
   end To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String (Self : Table_Sets.Set) return Unbounded_String is
      Result : Unbounded_String;
      C      : Table_Sets.Cursor := First (Self);
   begin
      if Has_Element (C) then
         Append (Result, To_String (Element (C)));
         Next (C);
      end if;

      while Has_Element (C) loop
         Append (Result, ", ");
         Append (Result, To_String (Element (C)));
         Next (C);
      end loop;

      return Result;
   end To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String
     (Self : As_Field_Internal; Long : Boolean) return String
   is
      Has_Blank : Boolean := False;
   begin
      for J in Self.As'Range loop
         if Self.As (J) = ' ' then
            Has_Blank := True;
            exit;
         end if;
      end loop;

      if Has_Blank
        and then (Self.As (Self.As'First) /= '"'
                  or else Self.As (Self.As'Last) /= '"')
      then
         return To_String (Self.Renamed, Long)
           & " AS """ & Self.As.all & """";
      else
         return To_String (Self.Renamed, Long)
           & " AS " & Self.As.all;
      end if;
   end To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String
     (Self : Sorted_Field_Internal; Long : Boolean) return String is
   begin
      if Self.Ascending then
         return To_String (Self.Sorted, Long => Long) & " ASC";
      else
         return To_String (Self.Sorted, Long => Long) & " DESC";
      end if;
   end To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String
     (Self : Multiple_Args_Field_Internal; Long : Boolean) return String
   is
      C      : Field_List.Cursor := First (Self.List);
      Result : Unbounded_String;
   begin
      if Self.Func_Name /= null then
         Append (Result, Self.Func_Name.all);
      end if;

      if Has_Element (C) then
         Append (Result, To_String (Element (C), Long));
         Next (C);
      end if;

      while Has_Element (C) loop
         Append (Result, Self.Separator.all);
         Append (Result, To_String (Element (C), Long));
         Next (C);
      end loop;

      if Self.Suffix /= null then
         Append (Result, Self.Suffix.all);
      end if;

      return To_String (Result);
   end To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String
     (Self : Case_Stmt_Internal; Long : Boolean) return String
   is
      C : When_Lists.Cursor := First (Self.Criteria.List);
      Result : Unbounded_String;
   begin
      Append (Result, "CASE");
      while Has_Element (C) loop
         Append (Result, " WHEN "
                 & GNATCOLL.SQL_Impl.To_String (Element (C).Criteria)
                 & " THEN "
                 & To_String (Element (C).Field, Long));
         Next (C);
      end loop;

      if Self.Else_Clause /= No_Field_Pointer then
         Append
           (Result,
            " ELSE " & To_String (Self.Else_Clause, Long));
      end if;

      Append (Result, " END");
      return To_String (Result);
   end To_String;

   ---------
   -- "&" --
   ---------

   function "&" (Left, Right : SQL_Table_List) return SQL_Table_List is
      C      : Table_List.Cursor := Table_List.No_Element;
   begin
      if Left.Data.Data = null then
         return Right;
      end if;

      if Right.Data.Data /= null then
         C := First (Right.Data.Data.List);
      end if;

      while Has_Element (C) loop
         Append (Left.Data.Data.List, Element (C));
         Next (C);
      end loop;
      return Left;
   end "&";

   ---------
   -- "&" --
   ---------

   function "&"
     (Left : SQL_Table_List; Right : SQL_Single_Table'Class)
      return SQL_Table_List
   is
   begin
      if Left.Data.Data = null then
         return +Right;
      end if;

      Append (Left.Data.Data.List, Right);
      return Left;
   end "&";

   ---------
   -- "&" --
   ---------

   function "&" (Left, Right : SQL_Single_Table'Class) return SQL_Table_List is
      Result : SQL_Table_List;
   begin
      Result.Data.Data := new Table_List_Internal;
      Append (Result.Data.Data.List, Left);
      Append (Result.Data.Data.List, Right);
      return Result;
   end "&";

   ---------
   -- "+" --
   ---------

   function "+" (Left : SQL_Single_Table'Class) return SQL_Table_List is
      Result : SQL_Table_List;
   begin
      Result.Data.Data := new Table_List_Internal;
      Append (Result.Data.Data.List, Left);
      return Result;
   end "+";

   --------
   -- As --
   --------

   function As
     (Field : SQL_Field'Class; Name : String) return SQL_Field'Class
   is
      Data : constant As_Field_Internal_Access := new As_Field_Internal;
   begin
      Data.As      := new String'(Name);
      Data.Renamed := +Field;
      return SQL_Field_Any'
        (Table => null, Instance => null, Name => null,
         Data => (Ada.Finalization.Controlled with
                  Data => SQL_Field_Internal_Access (Data)));
   end As;

   ----------
   -- Desc --
   ----------

   function Desc (Field : SQL_Field'Class) return SQL_Field'Class is
      Data : constant Sorted_Field_Internal_Access :=
        new Sorted_Field_Internal;
   begin
      Data.Ascending := False;
      Data.Sorted    := +Field;
      return SQL_Field_Any'
        (Table => null, Instance => null, Name => null,
         Data => (Ada.Finalization.Controlled with
                  Data => SQL_Field_Internal_Access (Data)));
   end Desc;

   ---------
   -- Asc --
   ---------

   function Asc  (Field : SQL_Field'Class) return SQL_Field'Class is
      Data : constant Sorted_Field_Internal_Access :=
        new Sorted_Field_Internal;
   begin
      Data.Ascending := True;
      Data.Sorted    := +Field;
      return SQL_Field_Any'
        (Table => null, Instance => null, Name => null,
         Data => (Ada.Finalization.Controlled with
                  Data => SQL_Field_Internal_Access (Data)));
   end Asc;

   ------------------------
   -- Expression_Or_Null --
   ------------------------

   function Expression_Or_Null
     (Value : String) return Text_Fields.Field'Class is
   begin
      if Value = Null_String then
         return Text_Fields.From_String (Null_String);
      else
         return Text_Fields.Expression (Value);
      end if;
   end Expression_Or_Null;

   ------------------
   -- Float_To_SQL --
   ------------------

   function Float_To_SQL (Value : Float) return String is
      Img : constant String := Float'Image (Value);
   begin
      if Img (Img'First) = ' ' then
         return Img (Img'First + 1 .. Img'Last);
      else
         return Img;
      end if;
   end Float_To_SQL;

   --------------------
   -- Integer_To_SQL --
   --------------------

   function Integer_To_SQL (Value : Integer) return String is
      Img : constant String := Integer'Image (Value);
   begin
      if Img (Img'First) = ' ' then
         return Img (Img'First + 1 .. Img'Last);
      else
         return Img;
      end if;
   end Integer_To_SQL;

   -----------------
   -- Time_To_SQL --
   -----------------

   function Time_To_SQL (Value : Ada.Calendar.Time) return String is
      Adjusted : Time;
   begin
      --  Value is always considered as GMT, which is what we store in the
      --  database. Unfortunately, GNAT.Calendar.Time_IO converts that back to
      --  local time.

      if Value /= No_Time then
         Adjusted := Value - Duration (UTC_Time_Offset (Value)) * 60.0;
         return Image (Adjusted, "'%Y-%m-%d %H:%M:%S'");
      else
         return "NULL";
      end if;
   end Time_To_SQL;

   -----------------
   -- Date_To_SQL --
   -----------------

   function Date_To_SQL (Value : Ada.Calendar.Time) return String is
      Adjusted : Time;
   begin
      --  Value is always considered as GMT, which is what we store in the
      --  database. Unfortunately, GNAT.Calendar.Time_IO converts that back to
      --  local time.

      if Value /= No_Time then
         Adjusted := Value - Duration (UTC_Time_Offset (Value)) * 60.0;
         return Image (Adjusted, "'%Y-%m-%d'");
      else
         return "NULL";
      end if;
   end Date_To_SQL;

   -------------
   -- As_Days --
   -------------

   function As_Days (Count : Natural) return Time_Fields.Field'Class is
   begin
      return Time_Fields.From_String
        ("interval '" & Integer'Image (Count) & "days'");
   end As_Days;

   function As_Days (Count : Natural) return Date_Fields.Field'Class is
   begin
      return Date_Fields.From_String (Integer'Image (Count));
   end As_Days;

   ------------------
   -- At_Time_Zone --
   ------------------

   function At_Time_Zone
     (Field : Time_Fields.Field'Class; TZ : String)
      return Time_Fields.Field'Class
   is
      function Internal is new Time_Fields.Apply_Function
        (Time_Fields.Field, "", " at time zone '" & TZ & "'");
   begin
      return Internal (Field);
   end At_Time_Zone;

   ----------
   -- Free --
   ----------

   overriding procedure Free (Self : in out Multiple_Args_Field_Internal) is
   begin
      Free (Self.Suffix);
      Free (Self.Func_Name);
      Free (Self.Separator);
   end Free;

   ------------
   -- Concat --
   ------------

   function Concat (Fields : SQL_Field_List) return SQL_Field'Class is
      function Internal is new Field_List_Function ("", " || ", "");
   begin
      return Internal (Fields);
   end Concat;

   -----------
   -- Tuple --
   -----------

   function Tuple (Fields : SQL_Field_List) return SQL_Field'Class is
      function Internal is new Field_List_Function ("(", ", ", ")");
   begin
      return Internal (Fields);
   end Tuple;

   --------------
   -- Coalesce --
   --------------

   function Coalesce (Fields : SQL_Field_List) return SQL_Field'Class is
      function Internal is new Field_List_Function ("COALESCE (", ", ", ")");
   begin
      return Internal (Fields);
   end Coalesce;

   ---------
   -- "&" --
   ---------

   function "&" (List1, List2 : When_List) return When_List is
      Result : When_List;
      C      : When_Lists.Cursor := First (List2.List);
   begin
      Result := List1;
      while Has_Element (C) loop
         Append (Result.List, Element (C));
         Next (C);
      end loop;
      return Result;
   end "&";

   --------------
   -- SQL_When --
   --------------

   function SQL_When
     (Criteria : SQL_Criteria; Field : SQL_Field'Class) return When_List
   is
      Result : When_List;
   begin
      Append (Result.List, (Criteria, +Field));
      return Result;
   end SQL_When;

   --------------
   -- SQL_Case --
   --------------

   function SQL_Case
     (List : When_List; Else_Clause : SQL_Field'Class := Null_Field_Text)
      return SQL_Field'Class
   is
      Data : constant Case_Stmt_Internal_Access :=
        new Case_Stmt_Internal;
   begin
      Data.Criteria := List;
      if Else_Clause /= SQL_Field'Class (Null_Field_Text) then
         Data.Else_Clause := +Else_Clause;
      end if;
      return SQL_Field_Any'
        (Table => null, Instance => null, Name => null,
         Data => (Ada.Finalization.Controlled
                  with SQL_Field_Internal_Access (Data)));
   end SQL_Case;

   -------------
   -- To_Char --
   -------------

   function To_Char
     (Field : Time_Fields.Field'Class; Format : String)
      return Text_Fields.Field'Class
   is
      function Internal is new Text_Fields.Apply_Function
        (Time_Fields.Field, "TO_CHAR (", ", '" & Format & "')");
   begin
      return Internal (Field);
   end To_Char;

   -------------
   -- Extract --
   -------------

   function Extract
     (Field : Time_Fields.Field'Class; Attribute : String)
      return Time_Fields.Field'Class
   is
      function Internal is new Time_Fields.Apply_Function
        (Time_Fields.Field, "EXTRACT (" & Attribute & " from ");
   begin
      return Internal (Field);
   end Extract;

   -----------
   -- Lower --
   -----------

   function Lower
     (Field : Text_Fields.Field'Class) return Text_Fields.Field'Class
   is
      function Internal is new Text_Fields.Apply_Function
        (Text_Fields.Field, "LOWER (");
   begin
      return Internal (Field);
   end Lower;

   -------------
   -- Initcap --
   -------------

   function Initcap
     (Field : Text_Fields.Field'Class) return Text_Fields.Field'Class
   is
      function Internal is new Text_Fields.Apply_Function
        (Text_Fields.Field, "INITCAP (");
   begin
      return Internal (Field);
   end Initcap;

   --------------------
   -- Cast_To_String --
   --------------------

   function Cast_To_String
     (Field : SQL_Field'Class) return Text_Fields.Field'Class
   is
      function Internal is new Text_Fields.Apply_Function
        (SQL_Field, "CAST (", "AS TEXT)");
   begin
      return Internal (Field);
   end Cast_To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String
     (Self : Aggregate_Field_Internal; Long : Boolean) return String
   is
      C      : Field_List.Cursor := First (Self.Params);
      Result : Unbounded_String;
   begin
      Result := To_Unbounded_String (Self.Func.all & " (");

      if Has_Element (C) then
         Append (Result, To_String (Element (C), Long));
         Next (C);
      end if;

      while Has_Element (C) loop
         Append (Result, ", ");
         Append (Result, To_String (Element (C), Long));
         Next (C);
      end loop;

      if Self.Criteria /= No_Criteria then
         Append (Result, GNATCOLL.SQL_Impl.To_String (Self.Criteria));
      end if;

      Append (Result, ")");
      return To_String (Result);
   end To_String;

   -----------
   -- Apply --
   -----------

   function Apply
     (Func     : Aggregate_Function;
      Criteria : SQL_Criteria) return SQL_Field'Class
   is
      Data : constant Aggregate_Field_Internal_Access :=
        new Aggregate_Field_Internal;
   begin
      Data.Criteria := Criteria;
      Data.Func   := new String'(String (Func));
      return SQL_Field_Any'
        (Table => null, Instance => null, Name => null,
         Data => (Ada.Finalization.Controlled with
                  Data => SQL_Field_Internal_Access (Data)));
   end Apply;

   -----------
   -- Apply --
   -----------

   function Apply
     (Func   : Aggregate_Function;
      Fields : SQL_Field_List) return SQL_Field'Class
   is
      Data : constant Aggregate_Field_Internal_Access :=
        new Aggregate_Field_Internal;
   begin
      Data.Params := Fields;
      Data.Func   := new String'(String (Func));
      return SQL_Field_Any'
        (Table => null, Instance => null, Name => null,
         Data => (Ada.Finalization.Controlled with
                  Data => SQL_Field_Internal_Access (Data)));
   end Apply;

   -----------
   -- Apply --
   -----------

   function Apply
     (Func   : Aggregate_Function;
      Field  : SQL_Field'Class) return SQL_Field'Class
   is
      Data : constant Aggregate_Field_Internal_Access :=
        new Aggregate_Field_Internal;
   begin
      Data.Params := +Field;
      Data.Func   := new String'(String (Func));
      return SQL_Field_Any'
        (Table => null, Instance => null, Name => null,
         Data => (Ada.Finalization.Controlled with
                  Data => SQL_Field_Internal_Access (Data)));
   end Apply;

   ------------
   -- Adjust --
   ------------

   procedure Adjust (Self : in out Table_List_Data) is
   begin
      if Self.Data /= null then
         Self.Data.Refcount := Self.Data.Refcount + 1;
      end if;
   end Adjust;

   --------------
   -- Finalize --
   --------------

   procedure Finalize (Self : in out Table_List_Data) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Table_List_Internal, Table_List_Internal_Access);
   begin
      if Self.Data /= null then
         Self.Data.Refcount := Self.Data.Refcount - 1;
         if Self.Data.Refcount = 0 then
            Unchecked_Free (Self.Data);
         end if;
      end if;
   end Finalize;

   -------------
   -- To_List --
   -------------

   function To_List (Fields : SQL_Field_Array) return SQL_Field_List is
      S : SQL_Field_List;
   begin
      for A in Fields'Range loop
         Append (S, Fields (A));
      end loop;
      return S;
   end To_List;

   -------------
   -- Combine --
   -------------

   function Combine
     (Left, Right : SQL_Criteria; Op : SQL_Criteria_Type) return SQL_Criteria
   is
      List : Criteria_List.List;
      C    : Criteria_List.Cursor;
      Result : SQL_Criteria;
      Data   : SQL_Criteria_Data_Access;
   begin
      if Left = No_Criteria then
         return Right;
      elsif Right = No_Criteria then
         return Left;
      elsif Get_Data (Left).all in SQL_Criteria_Data'Class
        and then SQL_Criteria_Data (Get_Data (Left).all).Op = Op
      then
         List := SQL_Criteria_Data (Get_Data (Left).all).Criterias;

         if Get_Data (Right).all in SQL_Criteria_Data'Class
           and then SQL_Criteria_Data (Get_Data (Right).all).Op = Op
         then
            C := First (SQL_Criteria_Data (Get_Data (Right).all).Criterias);
            while Has_Element (C) loop
               Append (List, Element (C));
               Next (C);
            end loop;
         else
            Append (List, Right);
         end if;
      elsif Get_Data (Right).all in SQL_Criteria_Data'Class
        and then SQL_Criteria_Data (Get_Data (Right).all).Op = Op
      then
         List := SQL_Criteria_Data (Get_Data (Right).all).Criterias;
         Prepend (List, Left);
      else
         Append (List, Left);
         Append (List, Right);
      end if;

      Data := new SQL_Criteria_Data (Op);
      SQL_Criteria_Data (Data.all).Criterias := List;
      Set_Data (Result, Data);
      return Result;
   end Combine;

   --------------
   -- Overlaps --
   --------------

   function Overlaps (Left, Right : SQL_Field'Class) return SQL_Criteria is
   begin
      return Compare (Left, Right, Comparison_Overlaps'Access);
   end Overlaps;

   -----------
   -- "and" --
   -----------

   function "and" (Left, Right : SQL_Criteria)  return SQL_Criteria is
   begin
      return Combine (Left, Right, Criteria_And);
   end "and";

   ----------
   -- "or" --
   ----------

   function "or" (Left, Right : SQL_Criteria)  return SQL_Criteria is
   begin
      return Combine (Left, Right, Criteria_Or);
   end "or";

   -----------
   -- "and" --
   -----------

   function "and"
     (Left : SQL_Criteria; Right : Boolean_Fields.Field'Class)
      return SQL_Criteria is
   begin
      return Left and (Right = True);
   end "and";

   ----------
   -- "or" --
   ----------

   function "or"
     (Left : SQL_Criteria; Right : Boolean_Fields.Field'Class)
      return SQL_Criteria is
   begin
      return Left or (Right = True);
   end "or";

   -----------
   -- "not" --
   -----------

   function "not" (Left : Boolean_Fields.Field'Class) return SQL_Criteria is
   begin
      return Left = False;
   end "not";

   ------------
   -- SQL_In --
   ------------

   function SQL_In
     (Self : SQL_Field'Class; List : SQL_Field_List) return SQL_Criteria
   is
      Data : constant SQL_Criteria_Data_Access := new SQL_Criteria_Data'
        (GNATCOLL.SQL_Impl.SQL_Criteria_Data with
         Op => Criteria_In, Arg => +Self, List => List, others => <>);
      Result : SQL_Criteria;
   begin
      Set_Data (Result, Data);
      return Result;
   end SQL_In;

   function SQL_In
     (Self : SQL_Field'Class; Subquery : SQL_Query) return SQL_Criteria
   is
      Data : constant SQL_Criteria_Data_Access := new SQL_Criteria_Data'
        (GNATCOLL.SQL_Impl.SQL_Criteria_Data with
         Op => Criteria_In,
         Arg => +Self, Subquery => Subquery, others => <>);
      Result : SQL_Criteria;
   begin
      Set_Data (Result, Data);
      return Result;
   end SQL_In;

   function SQL_In
     (Self : SQL_Field'Class; List : String) return SQL_Criteria
   is
      Data : constant SQL_Criteria_Data_Access := new SQL_Criteria_Data'
        (GNATCOLL.SQL_Impl.SQL_Criteria_Data with
         Op => Criteria_In,
         Arg => +Self, In_String => To_Unbounded_String (List), others => <>);
      Result : SQL_Criteria;
   begin
      Set_Data (Result, Data);
      return Result;
   end SQL_In;

   ----------------
   -- SQL_Not_In --
   ----------------

   function SQL_Not_In
     (Self : SQL_Field'Class; List : SQL_Field_List) return SQL_Criteria
   is
      Data : constant SQL_Criteria_Data_Access := new SQL_Criteria_Data'
        (GNATCOLL.SQL_Impl.SQL_Criteria_Data with
         Op => Criteria_Not_In, Arg => +Self, List => List, others => <>);
      Result : SQL_Criteria;
   begin
      Set_Data (Result, Data);
      return Result;
   end SQL_Not_In;

   function SQL_Not_In
     (Self : SQL_Field'Class; Subquery : SQL_Query) return SQL_Criteria
   is
      Data : constant SQL_Criteria_Data_Access := new SQL_Criteria_Data'
        (GNATCOLL.SQL_Impl.SQL_Criteria_Data with
         Op => Criteria_Not_In,
         Arg => +Self, Subquery => Subquery, others => <>);
      Result : SQL_Criteria;
   begin
      Set_Data (Result, Data);
      return Result;
   end SQL_Not_In;

   -------------
   -- Is_Null --
   -------------

   function Is_Null (Self : SQL_Field'Class) return SQL_Criteria is
      Data : constant SQL_Criteria_Data_Access := new SQL_Criteria_Data'
          (GNATCOLL.SQL_Impl.SQL_Criteria_Data
           with Op => Criteria_Null, Arg3 => +Self);
      Result : SQL_Criteria;
   begin
      Set_Data (Result, Data);
      return Result;
   end Is_Null;

   -----------------
   -- Is_Not_Null --
   -----------------

   function Is_Not_Null (Self : SQL_Field'Class) return SQL_Criteria is
      Data : constant SQL_Criteria_Data_Access := new SQL_Criteria_Data'
          (GNATCOLL.SQL_Impl.SQL_Criteria_Data
           with Op => Criteria_Not_Null, Arg3 => +Self);
      Result : SQL_Criteria;
   begin
      Set_Data (Result, Data);
      return Result;
   end Is_Not_Null;

   ---------
   -- Any --
   ---------

   function Any (Self, Str : Text_Fields.Field'Class) return SQL_Criteria is
   begin
      return Compare
        (Self, Str, Comparison_Any'Access, Comparison_Parenthesis'Access);
   end Any;

   -----------
   -- Ilike --
   -----------

   function Ilike
     (Self : Text_Fields.Field'Class; Str : String) return SQL_Criteria is
   begin
      return Compare (Self, Expression (Str), Comparison_ILike'Access);
   end Ilike;

   ----------
   -- Like --
   ----------

   function Like
     (Self : Text_Fields.Field'Class; Str : String) return SQL_Criteria is
   begin
      return Compare (Self, Expression (Str), Comparison_Like'Access);
   end Like;

   -----------
   -- Ilike --
   -----------

   function Ilike
     (Self : Text_Fields.Field'Class; Field : SQL_Field'Class)
      return SQL_Criteria is
   begin
      return Compare (Self, Field, Comparison_Like'Access);
   end Ilike;

   ---------------
   -- Not_Ilike --
   ---------------

   function Not_Ilike
     (Self : Text_Fields.Field'Class; Str : String) return SQL_Criteria is
   begin
      return Compare (Self, Expression (Str), Comparison_Not_ILike'Access);
   end Not_Ilike;

   --------------
   -- Not_Like --
   --------------

   function Not_Like
     (Self : Text_Fields.Field'Class; Str : String) return SQL_Criteria is
   begin
      return Compare (Self, Expression (Str), Comparison_Not_Like'Access);
   end Not_Like;

   ---------------
   -- To_String --
   ---------------

   function To_String
     (Self : SQL_Criteria_Data; Long : Boolean := True) return String
   is
      Result : Unbounded_String;
      C      : Criteria_List.Cursor;
      C2     : Field_List.Cursor;
      Is_First : Boolean;
      Criteria : SQL_Criteria;
   begin
      case Self.Op is
         when Criteria_Criteria =>
            C := First (Self.Criterias);
            while Has_Element (C) loop
               if C /= First (Self.Criterias) then
                  case Self.Op is
                     when Criteria_And => Append (Result, " AND ");
                     when Criteria_Or  => Append (Result, " OR ");
                     when others       => null;
                  end case;
               end if;

               Criteria := Element (C);
               if Get_Data (Criteria).all in SQL_Criteria_Data'Class
                 and then SQL_Criteria_Data (Get_Data (Criteria).all).Op
                    in Criteria_Criteria
               then
                  Append (Result, "(");
                  Append (Result, GNATCOLL.SQL_Impl.To_String (Element (C)));
                  Append (Result, ")");
               else
                  Append (Result, GNATCOLL.SQL_Impl.To_String (Element (C)));
               end if;
               Next (C);
            end loop;

         when Criteria_In | Criteria_Not_In =>
            Result := To_Unbounded_String (To_String (Self.Arg, Long));

            if Self.Op = Criteria_In then
               Append (Result, " IN (");
            else
               Append (Result, " NOT IN (");
            end if;

            Is_First := True;
            C2 := First (Self.List);
            while Has_Element (C2) loop
               if not Is_First then
                  Append (Result, ",");
               end if;

               Is_First := False;
               Append (Result, To_String (Element (C2), Long));
               Next (C2);
            end loop;

            Append (Result, To_String (Self.Subquery));
            Append (Result, To_String (Self.In_String));
            Append (Result, ")");

         when Null_Criteria =>
            Result := To_Unbounded_String (To_String (Self.Arg3, Long));

            case Self.Op is
               when Criteria_Null     => Append (Result, " IS NULL");
               when Criteria_Not_Null => Append (Result, " IS NOT NULL");
               when others            => null;
            end case;

      end case;
      return To_String (Result);
   end To_String;

   --------------
   -- Finalize --
   --------------

   procedure Finalize (Self : in out Controlled_SQL_Query) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Query_Contents'Class, SQL_Query_Contents_Access);
   begin
      if Self.Data /= null then
         Self.Data.Refcount := Self.Data.Refcount - 1;
         if Self.Data.Refcount = 0 then
            Free (Self.Data.all);
            Unchecked_Free (Self.Data);
         end if;
      end if;
   end Finalize;

   ------------
   -- Adjust --
   ------------

   procedure Adjust (Self : in out Controlled_SQL_Query) is
   begin
      if Self.Data /= null then
         Self.Data.Refcount := Self.Data.Refcount + 1;
      end if;
   end Adjust;

   ----------------
   -- SQL_Select --
   ----------------

   function SQL_Select
     (Fields   : SQL_Field_Or_List'Class;
      From     : SQL_Table_Or_List'Class := Empty_Table_List;
      Where    : SQL_Criteria := No_Criteria;
      Group_By : SQL_Field_Or_List'Class := Empty_Field_List;
      Having   : SQL_Criteria := No_Criteria;
      Order_By : SQL_Field_Or_List'Class := Empty_Field_List;
      Limit    : Integer := -1;
      Offset   : Integer := -1;
      Distinct : Boolean := False;
      Auto_Complete : Boolean := False) return SQL_Query
   is
      Data : constant Query_Select_Contents_Access :=
        new Query_Select_Contents;
      Q    : SQL_Query;
   begin
      if Fields in SQL_Field'Class then
         Data.Fields := +SQL_Field'Class (Fields);
      else
         Data.Fields := SQL_Field_List (Fields);
      end if;

      if From in SQL_Table_List'Class then
         Data.Tables   := SQL_Table_List (From);
      else
         Data.Tables := +SQL_Single_Table'Class (From);
      end if;

      Data.Criteria := Where;

      if Group_By in SQL_Field'Class then
         Data.Group_By := +SQL_Field'Class (Group_By);
      else
         Data.Group_By := SQL_Field_List (Group_By);
      end if;

      Data.Having   := Having;

      if Order_By in SQL_Field'Class then
         Data.Order_By := +SQL_Field'Class (Order_By);
      else
         Data.Order_By := SQL_Field_List (Order_By);
      end if;

      Data.Limit    := Limit;
      Data.Offset   := Offset;
      Data.Distinct := Distinct;
      Q := (Contents =>
              (Ada.Finalization.Controlled
               with SQL_Query_Contents_Access (Data)));

      if Auto_Complete then
         GNATCOLL.SQL.Auto_Complete (Q);
      end if;

      return Q;
   end SQL_Select;

   ---------------
   -- To_String --
   ---------------

   function To_String
     (Self : Query_Select_Contents) return Unbounded_String
   is
      Result : Unbounded_String;
   begin
      Result := To_Unbounded_String ("SELECT ");
      if Self.Distinct then
         Append (Result, "DISTINCT ");
      end if;
      Append (Result, To_String (Self.Fields, Long => True));
      if Self.Tables /= Empty_Table_List
        or else not Is_Empty (Self.Extra_Tables)
      then
         Append (Result, " FROM ");
         if Self.Tables.Data.Data = null
           or else Is_Empty (Self.Tables.Data.Data.List)
         then
            Append (Result, To_String (Self.Extra_Tables));
         elsif Is_Empty (Self.Extra_Tables) then
            Append (Result, To_String (Self.Tables));
         else
            Append (Result, To_String (Self.Tables));
            Append (Result, ", ");
            Append (Result, To_String (Self.Extra_Tables));
         end if;
      end if;
      if Self.Criteria /= No_Criteria then
         Append (Result, " WHERE ");
         Append (Result, GNATCOLL.SQL_Impl.To_String (Self.Criteria));
      end if;
      if Self.Group_By /= Empty_Field_List then
         Append (Result, " GROUP BY ");
         Append (Result, To_String (Self.Group_By, Long => True));
         if Self.Having /= No_Criteria then
            Append (Result, " HAVING ");
            Append (Result, GNATCOLL.SQL_Impl.To_String (Self.Having));
         end if;
      end if;
      if Self.Order_By /= Empty_Field_List then
         Append (Result, " ORDER BY ");
         Append (Result, To_String (Self.Order_By, Long => True));
      end if;
      if Self.Offset >= 0 then
         Append (Result, " OFFSET" & Integer'Image (Self.Offset));
      end if;
      if Self.Limit >= 0 then
         Append (Result, " LIMIT" & Integer'Image (Self.Limit));
      end if;
      return Result;
   end To_String;

   ---------------
   -- To_String --
   ---------------

   function To_String (Self : SQL_Query) return Unbounded_String is
   begin
      if Self.Contents.Data = null then
         return Null_Unbounded_String;
      else
         return To_String (Self.Contents.Data.all);
      end if;
   end To_String;

   ----------
   -- Free --
   ----------

   procedure Free (Self : in out As_Field_Internal) is
   begin
      Free (Self.As);
   end Free;

   ----------
   -- Free --
   ----------

   procedure Free (Self : in out Aggregate_Field_Internal) is
   begin
      Free (Self.Func);
   end Free;

   -------------------
   -- Auto_Complete --
   -------------------

   procedure Auto_Complete
     (Self                   : in out Query_Select_Contents;
      Auto_Complete_From     : Boolean := True;
      Auto_Complete_Group_By : Boolean := True)
   is
      List2  : Table_Sets.Set;
      Group_By : SQL_Field_List;
      Has_Aggregate : Boolean := False;
   begin
      if Auto_Complete_From then
         --  For each field, make sure the table is in the list
         Append_Tables (Self.Fields, Self.Extra_Tables);
         Append_Tables (Self.Group_By, Self.Extra_Tables);
         Append_Tables (Self.Order_By, Self.Extra_Tables);
         Append_Tables (Self.Criteria, Self.Extra_Tables);
         Append_Tables (Self.Having, Self.Extra_Tables);

         Append_Tables (Self.Tables, List2);
         Difference (Self.Extra_Tables, List2);
      end if;

      if Auto_Complete_Group_By then
         Append_If_Not_Aggregate (Self.Fields,   Group_By, Has_Aggregate);
         Append_If_Not_Aggregate (Self.Order_By, Group_By, Has_Aggregate);
         Append_If_Not_Aggregate (Self.Having,   Group_By, Has_Aggregate);
         if Has_Aggregate then
            Self.Group_By := Group_By;
         end if;
      end if;
   end Auto_Complete;

   -------------------
   -- Auto_Complete --
   -------------------

   procedure Auto_Complete
     (Self                   : in out SQL_Query;
      Auto_Complete_From     : Boolean := True;
      Auto_Complete_Group_By : Boolean := True) is
   begin
      Auto_Complete
        (Self.Contents.Data.all, Auto_Complete_From, Auto_Complete_Group_By);
   end Auto_Complete;

   -------------------
   -- Append_Tables --
   -------------------

   procedure Append_Tables
     (Self : SQL_Criteria_Data; To : in out Table_Sets.Set)
   is
      C    : Criteria_List.Cursor;
   begin
      case Self.Op is
         when Criteria_Criteria =>
            C := First (Self.Criterias);
            while Has_Element (C) loop
               Append_Tables (Element (C), To);
               Next (C);
            end loop;

         when Criteria_In | Criteria_Not_In =>
            Append_Tables (Self.Arg, To);

         when Null_Criteria =>
            Append_Tables (Self.Arg3, To);
      end case;
   end Append_Tables;

   -------------------
   -- Append_Tables --
   -------------------

   procedure Append_Tables
     (Self : SQL_Left_Join_Table; To : in out Table_Sets.Set)
   is
      C : Table_List.Cursor;
   begin
      if Self.Data.Data.Tables.Data.Data /= null then
         C := First (Self.Data.Data.Tables.Data.Data.List);
         while Has_Element (C) loop
            Append_Tables (Element (C), To);
            Next (C);
         end loop;
      end if;
   end Append_Tables;

   -------------------
   -- Append_Tables --
   -------------------

   procedure Append_Tables (Self : SQL_Table; To : in out Table_Sets.Set) is
   begin
      if Self.Table_Name /= null then
         Include (To, (Name     => Self.Table_Name,
                       Instance => Self.Instance));
      end if;
   end Append_Tables;

   -------------------
   -- Append_Tables --
   -------------------

   procedure Append_Tables
     (Self : SQL_Table_List; To : in out Table_Sets.Set)
   is
      C : Table_List.Cursor;
   begin
      if Self.Data.Data /= null then
         C := First (Self.Data.Data.List);
         while Has_Element (C) loop
            Append_Tables (Element (C), To);
            Next (C);
         end loop;
      end if;
   end Append_Tables;

   -------------------
   -- Append_Tables --
   -------------------

   procedure Append_Tables
     (From : SQL_Field_List; To : in out Table_Sets.Set)
   is
      C : Field_List.Cursor := First (From);
   begin
      while Has_Element (C) loop
         Append_Tables (Element (C), To);
         Next (C);
      end loop;
   end Append_Tables;

   -------------------
   -- Append_Tables --
   -------------------

   procedure Append_Tables
     (Self : As_Field_Internal; To : in out Table_Sets.Set) is
   begin
      Append_Tables (Self.Renamed, To);
   end Append_Tables;

   -------------------
   -- Append_Tables --
   -------------------

   procedure Append_Tables
     (Self : Sorted_Field_Internal; To : in out Table_Sets.Set) is
   begin
      Append_Tables (Self.Sorted, To);
   end Append_Tables;

   -------------------
   -- Append_Tables --
   -------------------

   procedure Append_Tables
     (Self : Multiple_Args_Field_Internal; To : in out Table_Sets.Set)
   is
      C : Field_List.Cursor := First (Self.List);
   begin
      while Has_Element (C) loop
         Append_Tables (Element (C), To);
         Next (C);
      end loop;
   end Append_Tables;

   -------------------
   -- Append_Tables --
   -------------------

   procedure Append_Tables
     (Self : Case_Stmt_Internal; To : in out Table_Sets.Set)
   is
      C : When_Lists.Cursor := First (Self.Criteria.List);
   begin
      while Has_Element (C) loop
         Append_Tables (Element (C).Field, To);
         Next (C);
      end loop;

      if Self.Else_Clause /= No_Field_Pointer then
         Append_Tables (Self.Else_Clause, To);
      end if;
   end Append_Tables;

   -------------------
   -- Append_Tables --
   -------------------

   procedure Append_Tables
     (Self : Aggregate_Field_Internal; To : in out Table_Sets.Set)
   is
      C : Field_List.Cursor := First (Self.Params);
   begin
      while Has_Element (C) loop
         Append_Tables (Element (C), To);
         Next (C);
      end loop;
      Append_Tables (Self.Criteria, To);
   end Append_Tables;

   -----------------------------
   -- Append_If_Not_Aggregate --
   -----------------------------

   procedure Append_If_Not_Aggregate
     (Self         : SQL_Field_List;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean)
   is
      C : Field_List.Cursor := First (Self);
   begin
      while Has_Element (C) loop
         Append_If_Not_Aggregate (Element (C), To, Is_Aggregate);
         Next (C);
      end loop;
   end Append_If_Not_Aggregate;

   -----------------------------
   -- Append_If_Not_Aggregate --
   -----------------------------

   procedure Append_If_Not_Aggregate
     (Self         : access As_Field_Internal;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean) is
   begin
      Append_If_Not_Aggregate (Self.Renamed, To, Is_Aggregate);
   end Append_If_Not_Aggregate;

   -----------------------------
   -- Append_If_Not_Aggregate --
   -----------------------------

   procedure Append_If_Not_Aggregate
     (Self         : access Sorted_Field_Internal;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean) is
   begin
      Append_If_Not_Aggregate (Self.Sorted, To, Is_Aggregate);
   end Append_If_Not_Aggregate;

   -----------------------------
   -- Append_If_Not_Aggregate --
   -----------------------------

   procedure Append_If_Not_Aggregate
     (Self         : access Multiple_Args_Field_Internal;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean)
   is
      C : Field_List.Cursor := First (Self.List);
   begin
      while Has_Element (C) loop
         Append_If_Not_Aggregate (Element (C), To, Is_Aggregate);
         Next (C);
      end loop;
   end Append_If_Not_Aggregate;

   -----------------------------
   -- Append_If_Not_Aggregate --
   -----------------------------

   procedure Append_If_Not_Aggregate
     (Self         : access Case_Stmt_Internal;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean)
   is
      C : When_Lists.Cursor := First (Self.Criteria.List);
   begin
      while Has_Element (C) loop
         Append_If_Not_Aggregate (Element (C).Criteria, To, Is_Aggregate);
         Append_If_Not_Aggregate (Element (C).Field, To, Is_Aggregate);
         Next (C);
      end loop;

      if Self.Else_Clause /= No_Field_Pointer then
         Append_If_Not_Aggregate (Self.Else_Clause, To, Is_Aggregate);
      end if;
   end Append_If_Not_Aggregate;

   -----------------------------
   -- Append_If_Not_Aggregate --
   -----------------------------

   procedure Append_If_Not_Aggregate
     (Self         : SQL_Criteria_Data;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean)
   is
      C    : Criteria_List.Cursor;
   begin
      case Self.Op is
         when Criteria_Criteria =>
            C := First (Self.Criterias);
            while Has_Element (C) loop
               Append_If_Not_Aggregate (Element (C), To, Is_Aggregate);
               Next (C);
            end loop;

         when Criteria_In | Criteria_Not_In =>
            Append_If_Not_Aggregate (Self.Arg, To, Is_Aggregate);

         when Null_Criteria =>
            Append_If_Not_Aggregate (Self.Arg3, To, Is_Aggregate);
      end case;
   end Append_If_Not_Aggregate;

   -----------------------------
   -- Append_If_Not_Aggregate --
   -----------------------------

   procedure Append_If_Not_Aggregate
     (Self         : access Aggregate_Field_Internal;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean)
   is
      pragma Unreferenced (Self, To);
   begin
      Is_Aggregate := True;
   end Append_If_Not_Aggregate;

   ----------------
   -- SQL_Delete --
   ----------------

   function SQL_Delete
     (From     : SQL_Table'Class;
      Where    : SQL_Criteria := No_Criteria) return SQL_Query
   is
      Data : constant Query_Delete_Contents_Access :=
        new Query_Delete_Contents;
   begin
      Data.Table := +From;
      Data.Where := Where;
      return (Contents =>
              (Ada.Finalization.Controlled
               with SQL_Query_Contents_Access (Data)));
   end SQL_Delete;

   ---------------
   -- To_String --
   ---------------

   function To_String (Self : Query_Delete_Contents) return Unbounded_String is
      Result : Unbounded_String;
   begin
      Result := To_Unbounded_String ("DELETE FROM ");
      Append (Result, To_String (Element (First (Self.Table.Data.Data.List))));

      if Self.Where /= No_Criteria then
         Append (Result, " WHERE ");
         Append
           (Result, GNATCOLL.SQL_Impl.To_String (Self.Where, Long => False));
      end if;

      return Result;
   end To_String;

   -------------------------------
   -- SQL_Insert_Default_Values --
   -------------------------------

   function SQL_Insert_Default_Values
     (Table : SQL_Table'Class) return SQL_Query
   is
      Data : constant Query_Insert_Contents_Access :=
        new Query_Insert_Contents;
   begin
      Data.Into := (Name     => Table.Table_Name,
                    Instance => Table.Instance);
      Data.Default_Values := True;
      return (Contents =>
              (Ada.Finalization.Controlled
               with SQL_Query_Contents_Access (Data)));
   end SQL_Insert_Default_Values;

   ----------------
   -- SQL_Insert --
   ----------------

   function SQL_Insert
     (Fields   : SQL_Field_Or_List'Class;
      Values   : SQL_Query) return SQL_Query
   is
      Data : constant Query_Insert_Contents_Access :=
        new Query_Insert_Contents;
      Q    : SQL_Query;
   begin
      if Fields in SQL_Field'Class then
         Data.Fields := +SQL_Field'Class (Fields);
      else
         Data.Fields := SQL_Field_List (Fields);
      end if;

      Data.Into   := No_Names;
      Data.Subquery := Values;
      Q := (Contents =>
              (Ada.Finalization.Controlled
               with SQL_Query_Contents_Access (Data)));
      Auto_Complete (Q);
      return Q;
   end SQL_Insert;

   ----------------
   -- SQL_Insert --
   ----------------

   function SQL_Insert
     (Values : SQL_Assignment;
      Where  : SQL_Criteria := No_Criteria) return SQL_Query
   is
      Data : constant Query_Insert_Contents_Access :=
        new Query_Insert_Contents;
      Q    : SQL_Query;
   begin
      Data.Into   := No_Names;
      Data.Values := Values;
      Data.Where  := Where;
      Q := (Contents =>
              (Ada.Finalization.Controlled
               with SQL_Query_Contents_Access (Data)));
      Auto_Complete (Q);
      return Q;
   end SQL_Insert;

   ---------------
   -- To_String --
   ---------------

   function To_String (Self : Query_Insert_Contents) return Unbounded_String is
      Result : Unbounded_String;
   begin
      Result := To_Unbounded_String ("INSERT INTO ");
      Append (Result, To_String (Self.Into));

      if Self.Default_Values then
         Append (Result, " DEFAULT VALUES");
      else
         if Self.Fields /= Empty_Field_List then
            Append (Result, " (");
            Append (Result, To_String (Self.Fields, Long => False));
            Append (Result, ")");
         end if;

         declare
            Assign : constant String :=
              To_String (Self.Values, With_Field => False);
         begin
            if Assign /= "" then
               Append (Result, " VALUES (" & Assign & ")");
            end if;
         end;

         if Self.Subquery /= No_Query then
            Append (Result, " ");
            Append (Result, To_String (Self.Subquery));
         end if;
      end if;

      return Result;
   end To_String;

   -------------------
   -- Auto_Complete --
   -------------------

   procedure Auto_Complete
     (Self                   : in out Query_Insert_Contents;
      Auto_Complete_From     : Boolean := True;
      Auto_Complete_Group_By : Boolean := True)
   is
      pragma Unreferenced (Auto_Complete_Group_By);
      List, List2 : Table_Sets.Set;
      Subfields   : SQL_Field_List;
   begin
      if Auto_Complete_From then

         --  Get the list of fields first, so that we'll also know what table
         --  is being updated

         if Self.Fields = Empty_Field_List then
            Get_Fields (Self.Values, Self.Fields);
         end if;

         if Self.Into = No_Names then
            --  For each field, make sure the table is in the list
            Append_Tables (Self.Fields, List);

            --  We must have a single table here, or that's a bug
            if Length (List) /= 1 then
               raise Program_Error
                 with "Invalid list of fields to insert, they all must modify"
                   & " the same table";
            end if;

            --  Grab the table from the first field
            Self.Into := Element (First (List));
         end if;

         if Self.Subquery = No_Query then
            --  Do we have other tables impacted from the list of values we
            --  set for the fields ? If yes, we'll need to transform the
            --  simple query into a subquery

            Clear (List);
            Append_Tables (Self.Values, List);
            if Self.Into /= No_Names then
               Table_Sets.Include (List2, Self.Into);
            end if;

            Difference (List, List2);  --  Remove tables already in the list
            if Length (List) > 0 then
               To_List (Self.Values, Subfields);
               Self.Subquery := SQL_Select
                 (Fields => Subfields, Where => Self.Where);
               Auto_Complete (Self.Subquery);
               Self.Values := No_Assignment;
            end if;
         end if;
      end if;
   end Auto_Complete;

   ----------------
   -- SQL_Update --
   ----------------

   function SQL_Update
     (Table    : SQL_Table'Class;
      Set      : SQL_Assignment;
      Where    : SQL_Criteria := No_Criteria;
      From     : SQL_Table_Or_List'Class := Empty_Table_List) return SQL_Query
   is
      Data : constant Query_Update_Contents_Access :=
        new Query_Update_Contents;
   begin
      Data.Table := +Table;
      Data.Set   := Set;
      Data.Where := Where;

      if From in SQL_Table'Class then
         Data.From := +SQL_Table'Class (From);
      else
         Data.From := SQL_Table_List (From);
      end if;

      return (Contents =>
              (Ada.Finalization.Controlled
               with SQL_Query_Contents_Access (Data)));
   end SQL_Update;

   ---------------
   -- To_String --
   ---------------

   function To_String (Self : Query_Update_Contents) return Unbounded_String is
      Result : Unbounded_String;
   begin
      Result := To_Unbounded_String ("UPDATE ");
      Append (Result, To_String (Element (First (Self.Table.Data.Data.List))));

      Append (Result, " SET ");
      Append (Result, To_String (Self.Set, With_Field => True));

      if Self.From /= Empty_Table_List
        or else not Is_Empty (Self.Extra_From)
      then
         Append (Result, " FROM ");
         if Self.From.Data.Data = null
           or else Is_Empty (Self.From.Data.Data.List)
         then
            Append (Result, To_String (Self.Extra_From));
         elsif Is_Empty (Self.Extra_From) then
            Append (Result, To_String (Self.From));
         else
            Append (Result, To_String (Self.From));
            Append (Result, ", ");
            Append (Result, To_String (Self.Extra_From));
         end if;
      end if;

      if Self.Where /= No_Criteria then
         Append (Result, " WHERE ");
         Append
           (Result, GNATCOLL.SQL_Impl.To_String (Self.Where, Long => True));
      end if;
      return Result;
   end To_String;

   -------------------
   -- Auto_Complete --
   -------------------

   procedure Auto_Complete
     (Self                   : in out Query_Update_Contents;
      Auto_Complete_From     : Boolean := True;
      Auto_Complete_Group_By : Boolean := True)
   is
      pragma Unreferenced (Auto_Complete_Group_By);
      List2  : Table_Sets.Set;
   begin
      if Auto_Complete_From then
         --  For each field, make sure the table is in the list
         Append_Tables (Self.Set,   Self.Extra_From);
         Append_Tables (Self.Where, Self.Extra_From);

         --  Remove tables already in the list
         Append_Tables (Self.From,  List2);
         Append_Tables (Self.Table, List2);
         Difference (Self.Extra_From, List2);
      end if;
   end Auto_Complete;

   ------------
   -- Adjust --
   ------------

   procedure Adjust (Self : in out Join_Table_Data) is
   begin
      if Self.Data /= null then
         Self.Data.Refcount := Self.Data.Refcount + 1;
      end if;
   end Adjust;

   --------------
   -- Finalize --
   --------------

   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Join_Table_Internal, Join_Table_Internal_Access);

   procedure Finalize (Self : in out Join_Table_Data) is
   begin
      if Self.Data /= null then
         Self.Data.Refcount := Self.Data.Refcount - 1;
         if Self.Data.Refcount = 0 then
            Unchecked_Free (Self.Data);
         end if;
      end if;
   end Finalize;

   ---------------
   -- Left_Join --
   ---------------

   function Left_Join
     (Full    : SQL_Single_Table'Class;
      Partial : SQL_Single_Table'Class;
      On      : SQL_Criteria := No_Criteria) return SQL_Left_Join_Table
   is
      Criteria : SQL_Criteria := On;
   begin
      if Criteria = No_Criteria then
         --  We only provide auto-completion if both Full and Partial are
         --  simple tables (not the result of joins), otherwise it is almost
         --  impossible to get things right automatically (which tables should
         --  be involved ? In case of multiple paths between two tables, which
         --  path should we use ? ...)

         if Full not in SQL_Table'Class
           or else Partial in SQL_Table'Class
         then
            raise Program_Error with "Can only auto-complete simple tables";
         end if;

         Criteria :=
           FK (SQL_Table (Full), SQL_Table (Partial))
           and FK (SQL_Table (Partial), SQL_Table (Full)) and Criteria;
      end if;

      return Result : SQL_Left_Join_Table (Instance => null) do
         Result.Data := Join_Table_Data'
           (Ada.Finalization.Controlled with
            Data => new Join_Table_Internal'
              (Refcount     => 1,
               Tables       => Full & Partial,
               Is_Left_Join => True,
               On           => Criteria));
      end return;
   end Left_Join;

   ----------
   -- Join --
   ----------

   function Join
     (Table1 : SQL_Single_Table'Class;
      Table2 : SQL_Single_Table'Class;
      On     : SQL_Criteria := No_Criteria) return SQL_Left_Join_Table
   is
      R : constant SQL_Left_Join_Table := Left_Join (Table1, Table2, On);
   begin
      R.Data.Data.Is_Left_Join := False;
      return R;
   end Join;

   ------------
   -- Rename --
   ------------

   function Rename
     (Self : SQL_Left_Join_Table; Name : Cst_String_Access)
      return SQL_Left_Join_Table'Class
   is
      R : SQL_Left_Join_Table (Instance => Name);
   begin
      R.Data := Self.Data;
      return R;
   end Rename;

   ---------------
   -- To_String --
   ---------------

   function To_String (Self : Simple_Query_Contents) return Unbounded_String is
   begin
      return Self.Command;
   end To_String;

   --------------
   -- SQL_Lock --
   --------------

   function SQL_Lock (Table : SQL_Table'Class) return SQL_Query is
      Data : constant Simple_Query_Contents_Access :=
        new Simple_Query_Contents;
   begin
      Data.Command := To_Unbounded_String ("LOCK " & To_String (Table));
      return (Contents =>
              (Ada.Finalization.Controlled
               with SQL_Query_Contents_Access (Data)));
   end SQL_Lock;

   ---------------
   -- SQL_Begin --
   ---------------

   function SQL_Begin return SQL_Query is
      Data : constant Simple_Query_Contents_Access :=
        new Simple_Query_Contents;
   begin
      Data.Command := To_Unbounded_String ("BEGIN");
      return (Contents =>
              (Ada.Finalization.Controlled
               with SQL_Query_Contents_Access (Data)));
   end SQL_Begin;

   ------------------
   -- SQL_Rollback --
   ------------------

   function SQL_Rollback return SQL_Query is
      Data : constant Simple_Query_Contents_Access :=
        new Simple_Query_Contents;
   begin
      Data.Command := To_Unbounded_String ("ROLLBACK");
      return (Contents =>
              (Ada.Finalization.Controlled
               with SQL_Query_Contents_Access (Data)));
   end SQL_Rollback;

   ----------------
   -- SQL_Commit --
   ----------------

   function SQL_Commit return SQL_Query is
      Data : constant Simple_Query_Contents_Access :=
        new Simple_Query_Contents;
   begin
      Data.Command := To_Unbounded_String ("COMMIT");
      return (Contents =>
              (Ada.Finalization.Controlled
               with SQL_Query_Contents_Access (Data)));
   end SQL_Commit;

   --------------
   -- Subquery --
   --------------

   function Subquery
     (Query : SQL_Query'Class; Table_Name : Cst_String_Access)
      return Subquery_Table
   is
   begin
      return R : Subquery_Table (Instance => Table_Name) do
         R.Query := SQL_Query (Query);
      end return;
   end Subquery;

   ----------
   -- Free --
   ----------

   procedure Free (A : in out SQL_Table_Access) is
   begin
      Unchecked_Free (A);
   end Free;

   ---------------------------
   -- Clone_Select_Contents --
   ---------------------------

   function Clone_Select_Contents
     (Query : SQL_Query) return Query_Select_Contents_Access is
   begin
      if Query.Contents.Data.all not in Query_Select_Contents'Class then
         raise Program_Error with "not a SELECT query";
      end if;

      return new Query_Select_Contents'Class'
        (Query_Select_Contents_Access (Query.Contents.Data).all);
   end Clone_Select_Contents;

   ---------------
   -- Where_And --
   ---------------

   function Where_And
     (Query : SQL_Query; Where : SQL_Criteria) return SQL_Query
   is
      Q2       : SQL_Query;
      Contents : constant Query_Select_Contents_Access :=
        Clone_Select_Contents (Query);
   begin
      Contents.Criteria := Contents.Criteria and Where;
      Q2.Contents.Data := SQL_Query_Contents_Access (Contents);
      return Q2;
   end Where_And;

   --------------
   -- Where_Or --
   --------------

   function Where_Or
     (Query : SQL_Query; Where : SQL_Criteria) return SQL_Query
   is
      Q2       : SQL_Query;
      Contents : constant Query_Select_Contents_Access :=
        Clone_Select_Contents (Query);
   begin
      Contents.Criteria := Contents.Criteria or Where;
      Q2.Contents.Data := SQL_Query_Contents_Access (Contents);
      return Q2;
   end Where_Or;

   --------------
   -- Order_By --
   --------------

   function Order_By
     (Query : SQL_Query; Order_By : SQL_Field_Or_List'Class)
      return SQL_Query
   is
      Q2       : SQL_Query;
      Contents : constant Query_Select_Contents_Access :=
        Clone_Select_Contents (Query);
   begin
      if Order_By in SQL_Field'Class then
         Contents.Order_By := SQL_Field'Class (Order_By) & Contents.Order_By;
      else
         Contents.Order_By := SQL_Field_List (Order_By) & Contents.Order_By;
      end if;

      Q2.Contents.Data := SQL_Query_Contents_Access (Contents);
      return Q2;
   end Order_By;

   --------------
   -- Distinct --
   --------------

   function Distinct (Query : SQL_Query) return SQL_Query is
      Q2       : SQL_Query;
      Contents : constant Query_Select_Contents_Access :=
        Clone_Select_Contents (Query);
   begin
      Contents.Distinct := True;
      Q2.Contents.Data := SQL_Query_Contents_Access (Contents);
      return Q2;
   end Distinct;

   -----------
   -- Limit --
   -----------

   function Limit (Query : SQL_Query; Limit : Natural) return SQL_Query is
      Q2       : SQL_Query;
      Contents : constant Query_Select_Contents_Access :=
        Clone_Select_Contents (Query);
   begin
      Contents.Limit := Limit;
      Q2.Contents.Data := SQL_Query_Contents_Access (Contents);
      return Q2;
   end Limit;

   ------------
   -- Offset --
   ------------

   function Offset (Query : SQL_Query; Offset : Natural) return SQL_Query is
      Q2       : SQL_Query;
      Contents : constant Query_Select_Contents_Access :=
        Clone_Select_Contents (Query);
   begin
      Contents.Offset := Offset;
      Q2.Contents.Data := SQL_Query_Contents_Access (Contents);
      return Q2;
   end Offset;

end GNATCOLL.SQL;
