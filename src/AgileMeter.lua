-- AgileStatus Scene LUA code
-- Provides Actions based on Octopus Agile daily electricity rates

-- This module reads the prices published daily for the upcoming costs of electricity in 30 min slots.
-- It extracts the Peak and Minimum charging times, and sets flags to indicate when the periods have started. 
-- These can then be used to trigger scenes, e.g. to turn on car charging overnight, increase house temp prior to peak, and reduce it during peak hours.

--Create a Device...
--  	Vera --> Apps  --> Develop Apps  --> Create Device
--     	in "Upnp Device Filename" put D_PowerMeter1.xml
--	in Device Name put (for example) AgileMeter
--	Press Create Device.  After a restart the device will be created. Make a note of the DeviceId that Vera has assigned....
--	Note at this stage the Variable list will be empty.

--Create a Scene to hold this code
-- 	Paste this code into a Vera Scene Lua section
--	Edit the values below, put your DeviceId into the AgileDeviceId declaration...
--	change the Product and Tariff to the appropriate ones for your account (See your Octopus Dashboard for the values)
-- 	Press Submit on the Scene editor and ensure that Vera reloads. 
--  After reload is complete, run the scene manually
--	After 30s the main body willl be called for the first time, the variables will be created and the data fetched
--	To force an update of the Variables, edit the ValidTilEpoch value to something small, eg delete last digit

--To start the code automatically:
--   To ensure it survives a restart, add the following line in Startup with the appropriate Scene No for your install, ensure that 
-- luup.call_action(HAGWSID, "RunScene", {SceneNum = <SceneNo>}, 0) -- Run scene to start agile

--While code is running:
--	The code will call itself on the hour and half-hour (with a 5 sec delay to avoid any other actions at those times)
--	If the prices have been updated, and the Peak slot has finished for the day, then the Price and new Start and End times will be updated
--	The time will be checked against the Start and End times and a flag set to trigger actions or alerts:
--	InPeak = 1 when Price is above a user-defined threshold
--	InPrePeak = 1 for a user-defined period before peak rate starts
--	InLowest = 1 when average price is lowest for a userdefined time, e.g. 4 hours to charge house batteries, or 1 hour for a washing machine

--To use the flags:
--	If using AltUI, create a scene, add a trigger that is Watching one of the variables and add an appropriate action...
--	eg Watch InPrePeak  when 	new == 1    run Action to turn up Electric Heating Thermostat by 2deg
--	eg Watch InPeak, when   	new == 1    run Action to turn off EV Car Charging, and turn down Thermostat
--	eg Watch price, when  	new < 0  	   run Action to turn on everything
-- -----------------------------------------------------------------------------------------------
-- Written by Octoplayer
-- If you are thinking of joining Octopus Electricity supply, please consider using my introduction code...
-- it will get both of us a useful discount  -- share.octopus.energy/denim-koala-967
-- 
-- Version 1.0, Feb 2021 - Initial release
-- Version 1.1, Feb 2021 - Added Current and Next Price Variables, as suggested by Tony
-- Version 1.2, Mar 2021 - Added Vat inc option. Corrected error in min for Epoch conversion. Force reload of values on reboot. 
--                      - Ignore values > 24hrs ahead, modify peak detection to allow for restart during peak
-- Version 1.3, Mar 2021 - Fixed bug in Vat inc option. Removed duplicate declaration. Added Pricing display string
-- Version 1.4, Mar 2021 - Fixed duplication of CurrentPrice in Pricing
-- Version 1.5, Mar 2021 - Formated Min Price to 2 dp
-- version 1.6, Mar 2021 - Added timestamp for use by heartbeat, as have noticed an update was skipped
--                          Run time calcs in Zulu time, as Octopus data is always Z. Change display times to work for BST - Thanks CadWizzard


-- Code Start
_G.GetAgile = GetAgile -- make function global so it can be re-called

--Customise these input values for your requirements
local Product = "AGILE-18-02-21"
local Tariff = "E-1R-AGILE-18-02-21-H"
local PriceIncVAT = true
local PeakLevel = 21 -- above this level assumed to be in Peak rate
local PeakAlert = 1 -- number of halfhours before peak
local NCheapPeriods = 8 -- Cheapest period for N halfhours, eg 8 == 4 hours
local AgileMeterId = TRV2["AgileMeter"] -- Insert Device ID of Agile Meter eg 249,... Could make this automatic one day
-------------------------------------------------------------
-- Variables set by this routine:
    -- PeakStart        hh:mm / dd
    -- PeakEnd          hh:mm
    -- Lowest Price     pence inc or exc VAT
    -- Lowest Price Start hh:mm
    -- CurrentPrice     pence
    -- NextPrice        pence
    -- Status           String showing "in peak" | off peak | prepeak

    -- Pricing - string format of pricing for ease of display
    -- Inpeak -> 1 when peak pricing applies
    -- PrePeakAlert -> 1 prior to peak
    -- InLowest -> 1 during min price window
    --
    -- ----------------------------------------------------------
    -------------------------------------------------------------

function GetAgile()
    local json = require("dkjson")
    local tempfile = "/tmp/agile.json"
    local EMSID = "urn:micasaverde-com:serviceId:EnergyMetering1"

    local retData, js_res
    local price, LowestPrice = 0, math.huge
    local LowestPriceStartEpoch
    local PeakStart, PeakEnd, CheapStart = "", "H"
    local _NHrSum, _NHrMin
    local PeakStartEpoch, PeakEndEpoch, CheapStartEpoch, Now, NowZ

    local SMC =
        'curl "https://api.octopus.energy/v1/products/' ..
        Product .. "/electricity-tariffs/" .. Tariff .. '/standard-unit-rates/"'
    luup.log("Agile SMC: " .. SMC)

    os.execute(SMC .. " > " .. tempfile)
    luup.log("Agile HTTP Request done")

    for dataRaw in io.lines(tempfile) do
        if dataRaw ~= nil then
            luup.log("Agile Rate Return:" .. dataRaw)
            js_res = json.decode(dataRaw)
            Now = os.time() 
            local t = os.date("*t", Now)
            if t.isdst then -- In British Summer Time, take off one hour for Zulu
                NowZ = Now - 3600
            else
                NowZ = Now
            end

            ValidTil = js_res.results[1].valid_to -- extract the end time
            local Year, Month, Day, Hour, Mins, Secs =
                string.match(ValidTil, "(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)") -- split timestamp into components
            ValidTilEpoch = os.time({year = Year, month = Month, day = Day, hour = Hour, min = Mins, sec = Secs}) -- convert to Unix timestamp format
            local oldValidTil = (tonumber((luup.variable_get(EMSID, "ValidTilEpoch", AgileMeterId))) or 0)
            --luup.log("Agile Valid prev: " .. oldValidTil)

            local SlotsToGo = math.floor((ValidTilEpoch - NowZ) / 1800)   -- Get the number of 30 min slots between now and the latest value 
            if PriceIncVAT then
                luup.variable_set(EMSID, "CurrentPrice", js_res.results[SlotsToGo + 1].value_inc_vat, AgileMeterId)
                luup.variable_set(EMSID, "NextPrice", js_res.results[SlotsToGo].value_inc_vat, AgileMeterId)
            else
                luup.variable_set(EMSID, "CurrentPrice", js_res.results[SlotsToGo + 1].value_exc_vat, AgileMeterId)
                luup.variable_set(EMSID, "NextPrice", js_res.results[SlotsToGo].value_exc_vat, AgileMeterId)
            end
            luup.variable_set(EMSID, "Pricing", string.format("Price now=%.2f, next=%.2fp",luup.variable_get(EMSID, "CurrentPrice", AgileMeterId),
            luup.variable_get(EMSID, "NextPrice", AgileMeterId)), AgileMeterId)
            
            if (ValidTilEpoch > oldValidTil) and
                    (NowZ > tonumber((luup.variable_get(EMSID, "PeakEndEpoch", AgileMeterId) or 0)))
             then -- we have an update  and it is after today's peak
                luup.log("Agile Data updated: " .. Year .. Month .. Day .. Hour .. Mins .. Secs)
                luup.variable_set(EMSID, "ValidTil", Hour .. ":" .. Mins .. "/" .. Day, AgileMeterId)

                _NHrMin = math.huge -- just a large value to start
                i = math.max(1,SlotsToGo-47)  --Start with 24 hrs from Now, or first value
                repeat
                    if PriceIncVAT then
                        --luup.log("Agile Price INC vat: ")
                        price = js_res.results[i].value_inc_vat
                    else
                        --luup.log("Agile Price EXC vat: ")
                        price = js_res.results[i].value_exc_vat
                    end
                    luup.log("Agile price from = " .. js_res.results[i].valid_from .. ": " .. price)
                    if price < LowestPrice then
                        LowestPrice = price
                        LowestPriceStart = js_res.results[i].valid_from
                    end
                    if price > PeakLevel then
                        PeakStart = js_res.results[i].valid_from -- update this all the time that the value is above avg
                        if PeakEnd == "L" then -- has just gone high
                            PeakEnd = js_res.results[i].valid_to
                        end
                    else
                        if PeakEnd == "H" then -- first sample to go low
                            PeakEnd = "L"

                        end
                    end

                    _NHrSum = 0
                    for j = 0, NCheapPeriods - 1 do
                        _NHrSum = _NHrSum + js_res.results[i + j].value_exc_vat
                    end
                    if _NHrSum < _NHrMin then
                        luup.log(
                            "Agile new lowest price sum = " ..
                                js_res.results[i + NCheapPeriods - 1].valid_from .. ": " .. _NHrSum
                        )
                        _NHrMin = _NHrSum
                        CheapStart = js_res.results[i + NCheapPeriods - 1].valid_from
                    end
                    i = i+1
                until i > SlotsToGo and price <= PeakLevel  -- until now, or if in a peak, go to the start of the peak


                --luup.log("Agile lowest price = " .. LowestPrice .. " @ " .. LowestPriceStart)
                --luup.log("Agile Peak start = " .. PeakStart )
                --luup.log("Agile Peak end = " .. PeakEnd )
                --luup.log("Agile Cheap Start = " .. CheapStartStart )
                --luup.log("Agile Cheap Avg  = " .. _NHrMin/8 )


                ExtractDate (PeakStart, "PeakStart")
                ExtractDate (PeakEnd, "PeakEnd")
                ExtractDate (LowestPriceStart, "LowestPriceStart")
                ExtractDate (CheapStart, "CheapStart")
                ExtractDate (ValidTil, "ValidTil")
            end
        end
        
    end

    -- Set up recursive call on the half hour
    local interval = 1800 - Now % (1800) -- no of secs to next half hour
    luup.log("Agile... call again in: " .. interval)
    luup.call_delay("GetAgile", interval + 5) -- few sec delay to avoid other events
    luup.variable_set(EMSID, "NextUpdate", Now + interval + 5 , AgileMeterId)   
 

    --------------
    --Check if we are now in any particular charging zone

    PeakStartEpoch = tonumber((luup.variable_get(EMSID, "PeakStartEpoch", AgileMeterId))) or 0
    if NowZ > PeakStartEpoch and NowZ < tonumber((luup.variable_get(EMSID, "PeakEndEpoch", AgileMeterId))) then
        luup.variable_set(EMSID, "InPeak", 1, AgileMeterId)
        luup.variable_set(EMSID, "Status", "In Peak", AgileMeterId)
        
    else
        luup.variable_set(EMSID, "InPeak", 0, AgileMeterId)
        luup.variable_set(EMSID, "Status", "Standard", AgileMeterId)
    end

    CheapStartEpoch = tonumber((luup.variable_get(EMSID, "CheapStartEpoch", AgileMeterId))) or 0
    if NowZ > CheapStartEpoch and NowZ < CheapStartEpoch + 1800 * NCheapPeriods then
        luup.variable_set(EMSID, "InLowest", 1, AgileMeterId)
        luup.variable_set(EMSID, "Status", "Off Peak", AgileMeterId)
    else
        luup.variable_set(EMSID, "InLowest", 0, AgileMeterId)
    end
    if NowZ > PeakStartEpoch - PeakAlert * 1800 and NowZ < PeakStartEpoch then
        luup.variable_set(EMSID, "PrePeakAlert", 1, AgileMeterId)
        luup.variable_set(EMSID, "Status", "In PrePeak", AgileMeterId)
    else
        luup.variable_set(EMSID, "PrePeakAlert", 0, AgileMeterId)
    end


    luup.log("Agile Exit")

    return
end

function ExtractDate(sTimeStamp, StampName)
    -- Gets timestamp from Agile API format - always in GMT - Zulu time.
    local Year, Month, Day, Hour, Mins, Secs =
                string.match(sTimeStamp, "(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)") -- split timestamp into components
    local Epoch = os.time({year = Year, month = Month, day = Day, hour = Hour, min = Mins, sec = Secs}) -- convert to Unix timestamp format

    local t = os.date("*t", Epoch)  -- Convert back to time table to chack if in BST
    if t.isdst then -- In British Summer Time, add one hour
        Hour = Hour + 1
    end
    luup.variable_set(EMSID, StampName, Hour .. ":" .. Mins, AgileMeterId)  -- Save in hh:mm, in Local (Juliet) time
    luup.variable_set(EMSID, StampName.."Epoch", Epoch, AgileMeterId)
return
end
    
------------------------------------
-- Initial call to the routine
local interval = 30 -- wait 30s before first call
luup.log("Agile... call in: " .. interval)
luup.call_delay("GetAgile", interval)
luup.variable_set(EMSID, "ValidTilEpoch", 0, AgileMeterId)  -- Create values, and set to zero if existing to force an update
luup.variable_set(EMSID, "PeakEndEpoch", 0, AgileMeterId)


return
