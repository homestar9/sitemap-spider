<cfoutput>
Module Tester #getSystemSetting( "APPNAME", "Unknown" )#

<cfdump var="#controller.getModuleService().getLoadedModules()#"/>
</cfoutput>