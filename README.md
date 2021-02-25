# Vera-OctopusAgile
Provides Actions based on Octopus Agile daily electricity rates

This module reads the prices published daily for the upcoming costs of electricity in 30 min slots.
It extracts the Peak and Minimum charging times, and sets flags to indicate when the periods have started. 
These can then be used to trigger scenes, e.g. to turn on car charging overnight, increase house temp prior to peak, and reduce it during peak hours.

The module requires manual creation of a device, then pasting the LUA code into a Scene, and calling it.

The Scene will create and populate a set of Variables and will update every 30 min on the half hour to flag when peak time has started etc.
You can then set a Variable Watch; it is easiest to do this in AltUI, to call Scenes when Peak time starts, or to alert user if the price is going negative.
Alternatively a Variable Watch can be programmed in the LUA Start Code module using: 
luup.variable_watch("var_watch", "urn:schemas-zerobrane-com:serviceId:SimplyVirtual1", nil, 4)

Using the Code...

 Create a Device...
  	Vera --> Apps  --> Develop Apps  --> Create Device
     	in "Upnp Device Filename" put D_PowerMeter1.xml
	in Device Name put (for example) AgileMeter
	Press Create Device.  After a restart the device will be created. Make a note of the DeviceId that Vera has assigned....
	Note at this stage the Variable list will be empty.
 Create a Scene to hold this code
 	Paste this code into a Vera Scene Lua section
	Edit the values below, put your DeviceId into the AgileDeviceId declaration...
	change the Product and Tariff to the appropriate ones for your account (See your Octopus Dashboard for the values)
 	Press Submit on the Scene editor and ensure that Vera reloads. 
	After 30s the main body willl be called for the first time, the variables will be created and the data fetched
 While code is running:
	The code will call itself on the hour and half-hour (with a 5 sec delay to avoid any other actions at those times)
	If the prices have been updated, and the Peak slot has finished for the day, then the Price and new Start and End times will be updated
	The time will be checked against the Start and End times and a flag set to trigger actions or alerts:
	InPeak = 1 when Price is above a user-defined threshold
	InPrePeak = 1 for a user-defined period before peak rate starts
	InLowest = 1 when average price is lowest for a userdefined time, e.g. 4 hours to charge house batteries, or 1 hour for a washing machine
 To use the flags:
	If using AltUI, create a scene, add a trigger that is Watching one of the variables and add an appropriate action...
	eg Watch InPrePeak  when 	new == 1    run Action to turn up Electric Heating Thermostat by 2deg
	eg Watch InPeak, when   	new == 1    run Action to turn off EV Car Charging, and turn down Thermostat
	eg Watch price, when  	new < 0  	   run Action to turn on everything
-----------------------------------------------------------------------------------------------
 Written by Octoplayer
 If you are thinking of joining Octopus Electricity supply, please consider using my introduction code...
 it will get both of us a useful discount  -- share.octopus.energy/denim-koala-967
-- 