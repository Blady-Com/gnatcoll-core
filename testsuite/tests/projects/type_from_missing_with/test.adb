with GNATCOLL.Projects; use GNATCOLL.Projects;
with GNATCOLL.VFS;      use GNATCOLL.VFS;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with GNATCOLL.Traces;   use GNATCOLL.Traces;
with GNATCOLL.Projects.Aux;
with Ada.Containers.Indefinite_Doubly_Linked_Lists;

with Test_Assert;

with Ada.Text_IO; use Ada.Text_IO;

function Test return Integer is
   PT              : Project_Tree;
   My_Root_Project : Project_Type;
   Env             : Project_Environment_Access;

   package String_Lists is new
     Ada.Containers.Indefinite_Doubly_Linked_Lists (String);
   use String_Lists;

   Lines : String_Lists.List;
   Cur   : String_Lists.Cursor;

   procedure Errors (S : String);
   procedure Errors (S : String) is
   begin
      Lines.Append (S);
   end Errors;

   Load_Failed : Boolean := False;
begin
   Initialize (Env);

   begin
      GNATCOLL.Projects.Load
        (PT,
         Root_Project_Path => Create_From_Base ("p.gpr"),
         Env => Env,
         Recompute_View => False,
         Errors => Errors'Unrestricted_Access);
   exception
      when Invalid_Project =>
         Load_Failed := True;
   end;

   Test_Assert.Assert (Load_Failed, "check that load failed");

   Cur := Lines.First;
   Test_Assert.Assert
     (Index
        (Element (Cur),
         "p.gpr:1:06: unknown project file: ""Common1.gpr""") /= 0,
      "check first error line");
   Next (Cur);
   Test_Assert.Assert
     (Index
        (Element (Cur),
         "p.gpr:3:10: unknown project ""common""") /= 0,
      "check second error line");
   Next (Cur);
   Test_Assert.Assert
     (Cur = No_Element, "check that there are no more error lines");
   Lines.Clear;

   GNATCOLL.Projects.Aux.Delete_All_Temp_Files (PT.Root_Project);

   PT.Unload;
   Free (Env);
   return Test_Assert.Report;
end Test;
