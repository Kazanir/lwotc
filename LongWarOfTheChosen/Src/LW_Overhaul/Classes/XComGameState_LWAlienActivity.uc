//---------------------------------------------------------------------------------------
//  FILE:    XComGameState_LWAlienActivity.uc
//  AUTHOR:  Amineri / Pavonis Interactive
//  PURPOSE: This models a single persistent alien activity, which can generate mission(s)
//---------------------------------------------------------------------------------------
class XComGameState_LWAlienActivity extends XComGameState_GeoscapeEntity config(LW_Overhaul);



var protected name							m_TemplateName;
var protected X2LWAlienActivityTemplate		m_Template;

var TDateTime		DateTimeStarted;						// When the activity was created (by the Activity Manager)
var TDateTime		DateTimeNextUpdate;						// The next time an intermediate update is schedule (may be never)
var TDateTime		DateTimeActivityComplete;				// The time when the activity will complete (may be never)
var TDateTime		DateTimeNextDiscoveryUpdate;			// The next time the activity is scheduled to check to see if it has been discovered by player (generally ever 6 hours)
var TDateTime		DateTimeCurrentMissionStarted;			// Have to store the time when the mission started, because base-game doesn't keep track of that

var float			MissionResourcePool;					// a local pool of effort spent detecting this activity by the local resistance outpost

var int				Doom;									// doom collected in this activity

var StateObjectReference			PrimaryRegion;			// The region the activity is taking place in
var array<StateObjectReference>		SecondaryRegions;		// Options secondary regions the activity affects in some way

var bool						bNeedsAppearedPopup;		// Does this POI need to show its popup for appearing for the first time?
var bool						bDiscovered;				// Has this activity been discovered, and its mission chain started?
var bool						bMustLaunch;				// Has time run out on the current mission so player must launch/abort at next opportunity?
var bool						bNeedsMissionCleanup;		// The mission should be deleted at the next safe opporunity
var bool						bNeedsPause;				// should pause geoscape at next opportunity
var bool						bNeedsUpdateMissionSuccess;  // the last mission succeeded, so update when we're back in geoscape
var bool						bNeedsUpdateMissionFailure;  // the last mission failed, so update when we're back in geoscape
var bool						bNeedsUpdateDiscovery;		// the mission was discovered while not in the geoscape, so needs to be detected now
var bool						bFailedFromMissionExpiration; // records that a mission failed because nobody went on it
var bool						bActivityComplete;			// an activity just completed, so need objectives UI update after submission
var StateObjectReference		CurrentMissionRef;			// The current mission in the chain, the one that is active
var int							CurrentMissionLevel;		// The depth in the activity's mission tree for the current mission
var GeneratedMissionData		CurrentMissionData;			// used only for accessing data, and matching

var StateObjectReference		DarkEvent;					//associated Dark Event, if any
var float						DarkEventDuration_Hours;	//randomized duration for the DarkEvent
var array<float>				arrDuration_Hours;			//randomized duration of all missions in the chain, filled out when activity is created

var MissionDefinition ForceMission;                         // A mission type to force to occur next.

// LWOTC: Allow configuration of which mission types the Chosen should be excluded from
var config array<string> ExcludeChosenFromMissionTypes;

//#############################################################################################
//----------------   REQUIRED FROM BASEOBJECT   -----------------------------------------------
//#############################################################################################

static function X2StrategyElementTemplateManager GetMyTemplateManager()
{
	return class'X2StrategyElementTemplateManager'.static.GetStrategyElementTemplateManager();
}

simulated function name GetMyTemplateName()
{
	return m_TemplateName;
}

simulated function X2LWAlienActivityTemplate GetMyTemplate()
{
	if (m_Template == none)
	{
		m_Template = X2LWAlienActivityTemplate(GetMyTemplateManager().FindStrategyElementTemplate(m_TemplateName));
	}
	return m_Template;
}

event OnCreation(optional X2DataTemplate InitTemplate)
{
	m_Template = X2LWAlienActivityTemplate(InitTemplate);
	m_TemplateName = InitTemplate.DataName;
}

function PostCreateInit(XComGameState NewGameState, StateObjectReference PrimaryRegionRef)
{
	PrimaryRegion = PrimaryRegionRef;

	SecondaryRegions = m_Template.ActivityCreation.GetSecondaryRegions(NewGameState, self);

	if(m_Template.OnActivityStartedFn != none)
		m_Template.OnActivityStartedFn(self, NewGameState);

	DateTimeStarted = class'XComGameState_GeoscapeEntity'.static.GetCurrentTime();

	m_Template.InstantiateActivityTimeline(self, NewGameState);

	if(m_Template.GetTimeUpdateFn != none)
		DateTimeNextUpdate = m_Template.GetTimeUpdateFn(self);
	else
		DateTimeNextUpdate.m_iYear = 9999; // never updates

	if(m_Template.ActivityCooldown != none)
		m_Template.ActivityCooldown.ApplyCooldown(self, NewGameState);

	if (m_Template.MissionTree[0].ForceActivityDetection)
	{
		bDiscovered = true;
		bNeedsAppearedPopup = true;
	}
	SpawnMission (NewGameState); // this initial mission will typically be hidden

	DateTimeNextDiscoveryUpdate = class'XComGameState_GeoscapeEntity'.static.GetCurrentTime();
}

//#############################################################################################
//----------------   UPDATE   -----------------------------------------------------------------
//#############################################################################################

//---------------------------------------------------------------------------------------
function bool Update(XComGameState NewGameState)
{
	local XComGameStateHistory History;
	local bool bUpdated;
	local X2LWAlienActivityTemplate ActivityTemplate;
	local XComGameState_MissionSite MissionState;
	local TDateTime TempUpdateDateTime;

	History = `XCOMHISTORY;
	MissionState = XComGameState_MissionSite(History.GetGameStateForObjectID(CurrentMissionRef.ObjectID));

	bUpdated = false;
	ActivityTemplate = GetMyTemplate();

	//handle deferred success/failure from post-mission gamelogic, which can't place new missions because it needs geoscape data
	if(bNeedsUpdateMissionSuccess)
	{
		ActivityTemplate.OnMissionSuccessFn(self, MissionState, NewGameState);
		bNeedsUpdateMissionSuccess = false;
		bUpdated = true;
		MissionState = XComGameState_MissionSite(History.GetGameStateForObjectID(CurrentMissionRef.ObjectID)); // regenerate the MissionState in case it was changed
	}
	else if(bNeedsUpdateMissionFailure)
	{
		ActivityTemplate.OnMissionFailureFn(self, MissionState, NewGameState);
		bNeedsUpdateMissionFailure = false;
		bFailedFromMissionExpiration = false;
		bUpdated = true;
		MissionState = XComGameState_MissionSite(History.GetGameStateForObjectID(CurrentMissionRef.ObjectID)); // regenerate the MissionState in case it was changed
	}

	if (bRemoved)
	{
		return bUpdated;
	}

	//handle intermediate updates to an activity
	TempUpdateDateTime = DateTimeNextUpdate;
	if (ActivityTemplate.UpdateModifierHoursFn != none)
	{
		class'X2StrategyGameRulesetDataStructures'.static.AddHours(TempUpdateDateTime, ActivityTemplate.UpdateModifierHoursFn(self, NewGameState));
	}
	if (class'X2StrategyGameRulesetDataStructures'.static.LessThan(TempUpdateDateTime, class'XComGameState_GeoscapeEntity'.static.GetCurrentTime()))
	{
		bUpdated = true;
		if(ActivityTemplate.OnActivityUpdateFn != none)
			ActivityTemplate.OnActivityUpdateFn(self, NewGameState);

		if(ActivityTemplate.GetTimeUpdateFn != none)
			DateTimeNextUpdate = ActivityTemplate.GetTimeUpdateFn(self, NewGameState);
	}

	//handle activity current mission expiration -- regular expiration mechanism don't allow us to query player for one last chance to go on mission while infiltrating
	if(MissionState != none && class'X2StrategyGameRulesetDataStructures'.static.LessThan(MissionState.ExpirationDateTime, class'XComGameState_GeoscapeEntity'.static.GetCurrentTime()))
	{
		bUpdated = true;
		if(`LWSQUADMGR.GetSquadOnMission(CurrentMissionRef) == none)
		{
			bNeedsUpdateMissionFailure = true;
			bFailedFromMissionExpiration = true;
			if(ActivityTemplate.OnMissionExpireFn != none)
				ActivityTemplate.OnMissionExpireFn(self, MissionState, NewGameState);
		}
		else
		{
			bNeedsAppearedPopup = true;	// Need a mission pop-up at next opportunity
			bMustLaunch = true;			// And the player has to either abort or launch
		}
	}

	//handle activity expiration
	if (class'X2StrategyGameRulesetDataStructures'.static.LessThan(DateTimeActivityComplete, class'XComGameState_GeoscapeEntity'.static.GetCurrentTime()))
	{
		if(ActivityTemplate.CanBeCompletedFn == none || ActivityTemplate.CanBeCompletedFn(self, NewGameState))
		{
			bUpdated = true;
			if(CurrentMissionRef.ObjectID == 0 || `LWSQUADMGR.GetSquadOnMission(CurrentMissionRef) == none)
			{
				if(CurrentMissionRef.ObjectID > 0)  // there is a mission, but no squad attached to it
				{
					// If the mission expired during this cycle too we've already cleaned it up just above and
					// set the bNeedsUpdateMissionFailure flag. Don't do it again.
					if (!bNeedsUpdateMissionFailure)
					{
						// mark the current mission to expire
						bNeedsUpdateMissionFailure = true;
						if(ActivityTemplate.OnMissionExpireFn != none)
							ActivityTemplate.OnMissionExpireFn(self, MissionState, NewGameState);
					}
				}
				else // no active mission, so silently clean up the activity
				{
					if(ActivityTemplate.OnActivityCompletedFn != none)
					{
						ActivityTemplate.OnActivityCompletedFn(true/*Alien Success*/, self, NewGameState);
						bActivityComplete = true;
					}
					NewGameState.RemoveStateObject(ObjectID);
				}
			}
			else
			{
				// there is a squad, so they get one last chance to complete the current mission
				bNeedsAppearedPopup = true;	// Need a mission pop-up at next opportunity
				bMustLaunch = true;			// And the player has to either abort or launch
			}
		}
	}

	// handle activity discovery, which generates first mission.
	// Missions cannot be detected if we set the bNeedsUpdateMissionFailure flag above (e.g. because it just expired). They also can't be detected
	// if the entire activity just expired (which either set this same flag if there was a mission, or removed the activity if there wasn't a mission).
	// In either case, skip detection altogther. If the activity still exists and only the mission expired, we'll loop back through here next update
	// cycle and will either clean up the activity (returning early so we won't get here) or generate a new mission in the chain (in which case we may
	// detect that one).
	if (!bNeedsUpdateMissionFailure && !bRemoved &&
		(bNeedsUpdateDiscovery || (!bDiscovered && class'X2StrategyGameRulesetDataStructures'.static.LessThan(DateTimeNextDiscoveryUpdate, class'XComGameState_GeoscapeEntity'.static.GetCurrentTime()))))
	{
		bUpdated = true;
		if(bNeedsUpdateDiscovery || (ActivityTemplate.DetectionCalc != none && ActivityTemplate.DetectionCalc.CanBeDetected(self, NewGameState)))
		{
			if (ActivityTemplate.MissionTree[CurrentMissionLevel].AdvanceMissionOnDetection)
			{
				if (MissionState != none) // clean up any existing mission -- we assume here that it's not possible for it to be infiltrated
				{
					if (MissionState.POIToSpawn.ObjectID > 0)
					{
						class'XComGameState_HeadquartersResistance'.static.DeactivatePOI(NewGameState, MissionState.POIToSpawn);
					}
					MissionState.RemoveEntity(NewGameState);
					MissionState = none;
					CurrentMissionRef.ObjectID = 0; 
				}
				CurrentMissionLevel++;
			}
			bDiscovered = true;
			bNeedsAppearedPopup = true;
			bNeedsUpdateDiscovery = false;
			if (MissionState == none)
			{
				SpawnMission(NewGameState);
			}
			else
			{
				MissionState = XComGameState_MissionSite(NewGameState.CreateStateObject(class'XComGameState_MissionSite', MissionState.ObjectID));
				MissionState.Available = true;
				NewGameState.AddStateObject(MissionState); 
			}
		}
		class'X2StrategyGameRulesetDataStructures'.static.AddHours(DateTimeNextDiscoveryUpdate, class'X2LWAlienActivityTemplate'.default.HOURS_BETWEEN_ALIEN_ACTIVITY_DETECTION_UPDATES);
	}

	return bUpdated;
}

//---------------------------------------------------------------------------------------
function UpdateGameBoard()
{
	local XComGameState NewGameState;
	local XComGameState_LWAlienActivity ActivityState;
	local XComGameStateHistory History;
	local UIStrategyMap StrategyMap;
	local bool ShouldPause, UpdateObjectiveUI;
	local XGGeoscape Geoscape;

	StrategyMap = `HQPRES.StrategyMap2D;
	if (StrategyMap != none && StrategyMap.m_eUIState != eSMS_Flight)
	{
		History = `XCOMHISTORY;
		NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Update Alien Activities");
		ActivityState = XComGameState_LWAlienActivity(NewGameState.CreateStateObject(class'XComGameState_LWAlienActivity', ObjectID));
		NewGameState.AddStateObject(ActivityState);

		if (!ActivityState.Update(NewGameState))
		{
			NewGameState.PurgeGameStateForObjectID(ActivityState.ObjectID);
		}
		else
		{
			ShouldPause = ActivityState.bNeedsPause;
			ActivityState.bNeedsPause = false;
			UpdateObjectiveUI = ActivityState.bActivityComplete;
			ActivityState.bActivityComplete = false;
		}
		if (NewGameState.GetNumGameStateObjects() > 0)
			`XCOMGAME.GameRuleset.SubmitGameState(NewGameState);
		else
			History.CleanupPendingGameState(NewGameState);

		if (ActivityState.bNeedsAppearedPopup && !ActivityState.bRemoved)
		{
			if(ActivityState.bMustLaunch)
			{
				ActivityState.SpawnInfiltrationUI();
			}
			else
			{
				ActivityState.SpawnMissionPopup();
			}
			NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Toggle Mission Appeared Popup");
			ActivityState = XComGameState_LWAlienActivity(NewGameState.CreateStateObject(class'XComGameState_LWAlienActivity', ObjectID));
			NewGameState.AddStateObject(ActivityState);
			ActivityState.bNeedsAppearedPopup = false;
			ActivityState.bMustLaunch = false;
			`XEVENTMGR.TriggerEvent('NewMissionAppeared', , , NewGameState);
			`XCOMGAME.GameRuleset.SubmitGameState(NewGameState);
		}
		if (ShouldPause)
		{
			Geoscape = `GAME.GetGeoscape();
			Geoscape.Pause();
			Geoscape.Resume();
			ShouldPause = false;
		}
		if (UpdateObjectiveUI)
		{
			class'X2StrategyGameRulesetDataStructures'.static.ForceUpdateObjectivesUI(); // this is to clean up "IN PROGRESS" after gamestate submission
		}
	}
}

function SpawnInfiltrationUI()
{
	local UIMission_LWLaunchDelayedMission MissionScreen;
	local XComHQPresentationLayer HQPres;

	HQPres = `HQPRES;
	MissionScreen = HQPres.Spawn(class'UIMission_LWLaunchDelayedMission', HQPres);
	MissionScreen.MissionRef = CurrentMissionRef;
	MissionScreen.bInstantInterp = false;
	MissionScreen = UIMission_LWLaunchDelayedMission(HQPres.ScreenStack.Push(MissionScreen));
}

function SpawnMissionPopup()
{
	local XComGameState_MissionSite MissionState;
	local XComHQPresentationLayer HQPres;
	local DynamicPropertySet PropertySet;

	HQPres = `HQPRES;

	if(CurrentMissionRef.ObjectID > 0)
		MissionState = XComGameState_MissionSite(`XCOMHISTORY.GetGameStateForObjectID(CurrentMissionRef.ObjectID));

	if(MissionState == none)
		return;

	HQPres.BuildUIAlert(
			PropertySet,
			GetAlertType(MissionState),
			MissionAlertCB,
			GetEventToTrigger(MissionState),
			GetSoundToPlay(MissionState));
	class'X2StrategyGameRulesetDataStructures'.static.AddDynamicIntProperty(PropertySet, 'MissionRef', MissionState.ObjectID);
	HQPres.QueueDynamicPopup(PropertySet);
}

simulated function MissionAlertCB(Name eAction, out DynamicPropertySet AlertData, optional bool bInstant = false)
{
	if (eAction == 'eUIAction_Accept')
	{
		if (UIMission(`HQPRES.ScreenStack.GetCurrentScreen()) == none)
		{
			TriggerMissionUI(XComGameState_MissionSite(`DYNAMIC_ID_PROP(AlertData, 'MissionRef')));
		}

		if (`GAME.GetGeoscape().IsScanning())
			`HQPRES.StrategyMap2D.ToggleScan();
	}
}

function float SecondsRemainingCurrentMission()
{
	local XComGameState_MissionSite MissionState;
	local float SecondsInMission, SecondsInActivity;
	local float TotalSeconds;

	if(CurrentMissionRef.ObjectID >= 0)
	{
		MissionState = XComGameState_MissionSite(`XCOMHISTORY.GetGameStateForObjectID(CurrentMissionRef.ObjectID));

		if (MissionState.ExpirationDateTime.m_iYear >= 2050)
			SecondsInMission = 2147483640;
		else
			SecondsInMission = class'X2StrategyGameRulesetDataStructures'.static.DifferenceInSeconds(MissionState.ExpirationDateTime, class'XComGameState_GeoscapeEntity'.static.GetCurrentTime());
		
		if (DateTimeActivityComplete.m_iYear >= 2050)
			SecondsInActivity = 2147483640;
		else
			SecondsInActivity = class'X2StrategyGameRulesetDataStructures'.static.DifferenceInSeconds(DateTimeActivityComplete, class'XComGameState_GeoscapeEntity'.static.GetCurrentTime());

		TotalSeconds = FMin(SecondsInMission, SecondsInActivity);
	}
	else  // no current mission
	{
		TotalSeconds = -1;
	}

	return TotalSeconds;
}

function int PercentCurrentMissionComplete()
{
	local XComGameState_MissionSite MissionState;
	local XComGameStateHistory History;
	local int TotalSeconds, RemainingSeconds, PctRemaining;

	History = `XCOMHISTORY;
	MissionState = XComGameState_MissionSite(History.GetGameStateForObjectID(CurrentMissionRef.ObjectID));
	PctRemaining = 0;
	if(MissionState.ExpirationDateTime.m_iYear < 2100)
	{
		TotalSeconds = class'X2StrategyGameRulesetDataStructures'.static.DifferenceInSeconds(MissionState.ExpirationDateTime, MissionState.TimerStartDateTime);
		RemainingSeconds = class'X2StrategyGameRulesetDataStructures'.static.DifferenceInHours(class'UIUtilities_Strategy'.static.GetGameTime().CurrentTime, MissionState.TimerStartDateTime);
		PctRemaining = int(float(RemainingSeconds) / float(TotalSeconds) * 100.0);
	}
	return PctRemaining;
}

function bool SpawnMission(XComGameState NewGameState)
{
	local name RewardName;
	local array<name> RewardNames;
	local XComGameState_Reward RewardState;
	local X2RewardTemplate RewardTemplate;
	local X2StrategyElementTemplateManager StratMgr;
	local array<XComGameState_Reward> MissionRewards;
	local X2LWAlienActivityTemplate ActivityTemplate;
	local XComGameState_MissionSite MissionState;
	local X2MissionSourceTemplate MissionSource;
	local XComGameState_WorldRegion PrimaryRegionState;
	local bool bExpiring, bHasPOIReward;
	local int idx;
	local Vector2D v2Loc;
	local name MissionFamily;
	local float SecondsUntilActivityComplete, DesiredSecondsOfMissionDuration;
	local XComGameState_HeadquartersResistance ResHQ;

	MissionFamily = GetNextMissionFamily(NewGameState);
	if(MissionFamily == '')
		return false;

	StratMgr = class'X2StrategyElementTemplateManager'.static.GetStrategyElementTemplateManager();

	PrimaryRegionState = XComGameState_WorldRegion(NewGameState.GetGameStateForObjectID(PrimaryRegion.ObjectID));
	if(PrimaryRegionState == none)
		PrimaryRegionState = XComGameState_WorldRegion(`XCOMHISTORY.GetGameStateForObjectID(PrimaryRegion.ObjectID));

	if(PrimaryRegionState == none)
		return false;

	ActivityTemplate = GetMyTemplate();

	// Generate the mission reward
	if(ActivityTemplate.GetMissionRewardsFn != none)
		RewardNames = ActivityTemplate.GetMissionRewardsFn(self, MissionFamily, NewGameState);
	else
		RewardNames[0] = 'Reward_None';

	idx = RewardNames.Find('Reward_POI_LW');
	if (idx != -1) // if there is a reward POI, peel it off and attach it to the MissionState so that DLCs can modify it to insert optional content
	{
		bHasPOIReward = true;
		RewardNames.Remove(idx, 1); // peel off the first Reward_POI, since base-game only supports one per mission.
	}

	foreach RewardNames(RewardName)
	{
		RewardTemplate = X2RewardTemplate(StratMgr.FindStrategyElementTemplate(RewardName)); 
		RewardState = RewardTemplate.CreateInstanceFromTemplate(NewGameState);
		RewardState.GenerateReward(NewGameState, 1.0 /*reward scalar */ , PrimaryRegion);
		MissionRewards.AddItem(RewardState);
	}

	// use a generic mission source that will link back to the activity
	MissionSource = X2MissionSourceTemplate(StratMgr.FindStrategyElementTemplate('MissionSource_LWSGenericMissionSource'));

	//set false so missions don't auto-expire and get cleaned up before we give player last chance to taken them on, if infiltrated
	bExpiring = false;

	//calculate mission location
	v2Loc = PrimaryRegionState.GetRandom2DLocationInRegion();
	if(v2Loc.x == -1 && v2Loc.y == -1)
	{
		
	}
    
    // Build Mission, region and loc will be determined later so defer computing biome/plot data
    if (ActivityTemplate.GetMissionSiteFn != none)
        MissionState = ActivityTemplate.GetMissionSiteFn(self, MissionFamily, NewGameState);
    else
	    MissionState = XComGameState_MissionSite(NewGameState.CreateNewStateObject(class'XComGameState_MissionSite'));

	// Add Dark Event if appropriate
	if(ActivityTemplate.GetMissionDarkEventFn != none)
		MissionState.DarkEvent = ActivityTemplate.GetMissionDarkEventFn(self, MissionFamily, NewGameState);

	MissionState.BuildMission(MissionSource,
									 v2Loc, 
									 PrimaryRegion, 
									 MissionRewards, 
									 bDiscovered, /*bAvailable*/
									 bExpiring, 
									 , /* Integer Hours Duration */
									 0, /* Integer Seconds Duration */
									 , /* bUseSpecifiedLevelSeed */
									 , /* LevelSeedOverride */
									 false /* bSetMissionData */
							   );

	//manually set the expiration time since we aren't setting the Expires flag true
	if (DateTimeActivityComplete.m_iYear >= 2090)
		SecondsUntilActivityComplete = 2147483640;
	else
		SecondsUntilActivityComplete = class'X2StrategyGameRulesetDataStructures'.static.DifferenceInSeconds(DateTimeActivityComplete, class'XComGameState_GeoscapeEntity'.static.GetCurrentTime());
	DesiredSecondsOfMissionDuration = 3600.0 * (arrDuration_Hours[CurrentMissionLevel] > 0 ? arrDuration_Hours[CurrentMissionLevel] : 500000.0);
	MissionState.TimeUntilDespawn = FMin(SecondsUntilActivityComplete, DesiredSecondsOfMissionDuration);
	MissionState.ExpirationDateTime = class'XComGameState_GeoscapeEntity'.static.GetCurrentTime();
	class'X2StrategyGameRulesetDataStructures'.static.AddTime(MissionState.ExpirationDateTime, MissionState.TimeUntilDespawn);

	MissionState.bMakesDoom = ActivityTemplate.MakesDoom;

	//add a POI to the mission state if one was specified earlier
	if (bHasPOIReward)
	{
		ResHQ = class'UIUtilities_Strategy'.static.GetResistanceHQ();
		MissionState.POIToSpawn = ResHQ.ChoosePOI(NewGameState);
	}

	if(MissionState == none)
	{
		`REDSCREEN("XCGS_LWAlienActivity : Unable to create mission");
		return false;
	}
	// Use a custom implemention of XCGS_MissionSite.SetMissionData to set mission family based on something other than reward
	SetMissionData(MissionFamily, MissionState, MissionRewards[0].GetMyTemplate(), NewGameState, false, 0);

	//store off the mission so we can match it after tactical mission complete
	CurrentMissionRef = MissionState.GetReference();

	DateTimeCurrentMissionStarted = class'UIUtilities_Strategy'.static.GetGameTime().CurrentTime;

	if(ActivityTemplate.OnMissionCreatedFn != none)
		ActivityTemplate.OnMissionCreatedFn(self, MissionState, NewGameState);

	return true;
} 

function name GetNextMissionFamily(XComGameState NewGameState)
{
	local X2LWAlienActivityTemplate ActivityTemplate;
	local array<name> PossibleMissionFamilies;
	local array<int> ExistingMissionFamilyCounts, SelectArray;
	local XComGameState_MissionSite MissionSite;
	local int idx, i, j, FamilyIdx;

	ActivityTemplate = GetMyTemplate();
	if (CurrentMissionLevel >= ActivityTemplate.MissionTree.Length)
		return '';

	PossibleMissionFamilies = ActivityTemplate.MissionTree[CurrentMissionLevel].MissionFamilies;

	if(PossibleMissionFamilies.Length > 0)
	{
		//count up how many visible missions there are of each type currently -- this more complex selection logic is to fix ID 713
		ExistingMissionFamilyCounts.length = PossibleMissionFamilies.length;
		foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_MissionSite', MissionSite)
		{
			if (MissionSite.Available)
			{
				idx = PossibleMissionFamilies.Find(name(MissionSite.GeneratedMission.Mission.MissionFamily));
				if (idx != -1)
				{
					ExistingMissionFamilyCounts[idx]++;
				}
			}
		}

		//set up a selection array where each instance of a mission family gets a single entry
		for (i = 0; i < ExistingMissionFamilyCounts.length; i++)
		{
			SelectArray.AddItem(i); // add one of each so that missions with 0 elements can still be selected
			for (j = 0; j < ExistingMissionFamilyCounts[i]; j++)
			{
				SelectArray.AddItem(i);
			}
		}

		if (SelectArray.length == 0)
		{
			return PossibleMissionFamilies[`SYNC_RAND_STATIC(PossibleMissionFamilies.length)];
		}
		else
		{
			while (SelectArray.length > 0)
			{
				FamilyIdx = SelectArray[`SYNC_RAND_STATIC(SelectArray.length)];  // randomly pick a mission family index from the SelectArray -- more represented missions are more likely to be selected
				SelectArray.RemoveItem(FamilyIdx); // removes all instances of that family index
			}
			return PossibleMissionFamilies[FamilyIdx]; // return the very last family to be removed
		}
	}
	return '';
}

function SetMissionData(name MissionFamily, XComGameState_MissionSite MissionState, X2RewardTemplate MissionReward, XComGameState NewGameState, bool bUseSpecifiedLevelSeed, int LevelSeedOverride)
{
	local GeneratedMissionData EmptyData;
	local XComTacticalMissionManager MissionMgr;
	local XComParcelManager ParcelMgr;
	local string Biome;
	// LWOTC vars
	local XComHeadquartersCheatManager CheatManager;
	local XComGameState_HeadquartersAlien AlienHQ;
	local X2MissionSourceTemplate MissionSource;
	local array<name> SourceSitReps;
	local name SitRepName;
	local array<name> SitRepNames;
	local String AdditionalTag;
	// End LWOTC vars

	MissionMgr = `TACTICALMISSIONMGR;
	ParcelMgr = `PARCELMGR;

	MissionState.GeneratedMission = EmptyData;
	MissionState.GeneratedMission.MissionID = MissionState.ObjectID;

    if (Len(ForceMission.sType) > 0)
    {
        // Force this mission to the desired type and then un-set the force mission type
        // so any subsequent missions are as normal.
        MissionState.GeneratedMission.Mission = ForceMission;
        ForceMission.sType = "";
    }
    else
    {
        MissionState.GeneratedMission.Mission = GetMissionDefinitionForFamily(MissionFamily);
    }

	MissionState.GeneratedMission.LevelSeed = (bUseSpecifiedLevelSeed) ? LevelSeedOverride : class'Engine'.static.GetEngine().GetSyncSeed();
	MissionState.GeneratedMission.BattleDesc = "";

	// LWOTC - copied from WOTC `XComGameState_MissionSite.SetMissionData()`
	//
	// This block basically adds support for spawning Chosen and adding SitReps
	MissionState.GeneratedMission.SitReps.Length = 0;
	SitRepNames.Length = 0;

	// Add Chosen to the mission based on various criteria (see method for info on what those criteria are)
	MaybeAddChosenToMission(MissionState);

	// Add additional required plot objective tags
	foreach MissionState.AdditionalRequiredPlotObjectiveTags(AdditionalTag)
	{
		MissionState.GeneratedMission.Mission.RequiredPlotObjectiveTags.AddItem(AdditionalTag);
	}

	MissionState.GeneratedMission.SitReps = MissionState.GeneratedMission.Mission.ForcedSitreps;
	SitRepNames = MissionState.GeneratedMission.Mission.ForcedSitreps;

	// Add Forced SitReps from Cheats
	CheatManager = XComHeadquartersCheatManager(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController().CheatManager);
	if (CheatManager != none && CheatManager.ForceSitRepTemplate != '')
	{
		MissionState.GeneratedMission.SitReps.AddItem(CheatManager.ForceSitRepTemplate);
		SitRepNames.AddItem(CheatManager.ForceSitRepTemplate);
		CheatManager.ForceSitRepTemplate = '';
	}
	else if (!MissionState.bForceNoSitRep)
	{
		// No cheats, add SitReps from the Mission Source
		MissionSource = MissionState.GetMissionSource();

		if (MissionSource.GetSitrepsFn != none)
		{
			SourceSitReps = MissionSource.GetSitrepsFn(MissionState);

			foreach SourceSitReps(SitRepName)
			{
				if (MissionState.GeneratedMission.SitReps.Find(SitRepName) == INDEX_NONE)
				{
					MissionState.GeneratedMission.SitReps.AddItem(SitRepName);
					SitRepNames.AddItem(SitRepName);
				}
			}
		}
	}
	// End LWOTC additions

	MissionState.GeneratedMission.MissionQuestItemTemplate = MissionMgr.ChooseQuestItemTemplate(MissionState.Source, MissionReward, MissionState.GeneratedMission.Mission, (MissionState.DarkEvent.ObjectID > 0));

	// WOTC TODO: Find out whether this is needed - SetBuildTime is no longer available on XCGS_MissionSite
	// MissionState.SetBuildTime(0);
	MissionState.bHasSeenSkipPopup = true;

	if(MissionState.GeneratedMission.Mission.sType == "")
	{
		`Redscreen("GetMissionDefinitionForFamily() failed to generate a mission with: \n"
						$ " Family: " $ MissionFamily);
	}

	// find a plot that supports the biome and the mission
	Biome = class'X2StrategyGameRulesetDataStructures'.static.GetBiome(MissionState.Get2DLocation());

	// do a weighted selection of our plot
	MissionState.GeneratedMission.Plot = SelectPlotDefinition(MissionState.GeneratedMission.Mission, Biome);  // have to use custom one because XCGS_MissionSite version is private
	MissionState.GeneratedMission.Biome = ParcelMgr.GetBiomeDefinition(Biome);

	if(MissionState.GetMissionSource().BattleOpName != "")
	{
		MissionState.GeneratedMission.BattleOpName = MissionState.GetMissionSource().BattleOpName;
	}
	else
	{
		MissionState.GeneratedMission.BattleOpName = class'XGMission'.static.GenerateOpName(false);
	}

	MissionState.GenerateMissionFlavorText();
}

function MissionDefinition GetMissionDefinitionForFamily(name MissionFamily)
{
	local X2CardManager CardManager;
	local MissionDefinition MissionDef;
	local array<string> DeckMissionTypes;
	local string MissionType;
	local XComTacticalMissionManager MissionMgr;

	MissionMgr = `TACTICALMISSIONMGR;
	// WOTC TODO: Cards should be cached by now! Maybe verify that's the case.
	// MissionMgr.CacheMissionManagerCards();  
	CardManager = class'X2CardManager'.static.GetCardManager();

	// now that we have a mission family, determine the mission type to use
	CardManager.GetAllCardsInDeck('MissionTypes', DeckMissionTypes);
	foreach DeckMissionTypes(MissionType)
	{
		if(MissionMgr.GetMissionDefinitionForType(MissionType, MissionDef))
		{
			if(MissionDef.MissionFamily == string(MissionFamily) 
				|| (MissionDef.MissionFamily == "" && MissionDef.sType == string(MissionFamily))) // missions without families are their own family
			{
				CardManager.MarkCardUsed('MissionTypes', MissionType);
				return MissionDef;
			}
		}
	}

	`Redscreen("AlienActivity: Could not find a mission type for MissionFamily: " $ MissionFamily);
	return MissionMgr.arrMissions[0];
}

function PlotDefinition SelectPlotDefinition(MissionDefinition MissionDef, string Biome)
{
	local XComParcelManager ParcelMgr;
	local array<PlotDefinition> ValidPlots;
	local PlotDefinition SelectedDef;

	ParcelMgr = `PARCELMGR;
	ParcelMgr.GetValidPlotsForMission(ValidPlots, MissionDef, Biome);

	// pull the first one that isn't excluded from strategy, they are already in order by weight
	foreach ValidPlots(SelectedDef)
	{
		if(!SelectedDef.ExcludeFromStrategy)
			return SelectedDef;
	}
	`Redscreen("Could not find valid plot for mission!\n" $ " MissionType: " $ MissionDef.MissionName);
	return ParcelMgr.arrPlots[0];
}

function string GetMissionDescriptionForActivity()
{
	local X2LWAlienActivityTemplate Template;
	local ActivityMissionDescription MissionDescription;
	local XComGameState_MissionSite MissionState;
	local name MissionFamily;
	local string DescriptionText;

	Template = GetMyTemplate();
	MissionState = XComGameState_MissionSite(`XCOMHISTORY.GetGameStateForObjectID(CurrentMissionRef.ObjectID));
	if (MissionState != none)
	{
		MissionFamily = name(MissionState.GeneratedMission.Mission.MissionFamily);
		if (MissionFamily == '')
			MissionFamily = name(MissionState.GeneratedMission.Mission.sType);
		foreach Template.MissionDescriptions(MissionDescription)
		{
			if (MissionDescription.MissionIndex < 0 || MissionDescription.MissionIndex == CurrentMissionLevel)
			{
				if (MissionDescription.MissionFamily == MissionFamily)
				{
					DescriptionText = MissionDescription.Description;
					break;
				}
			}
		}
	}
	if (DescriptionText == "")
		DescriptionText = "MISSING DESCRIPTION ASSIGNED FOR THIS COMBINATION: \n" $ Template.DataName $ ", " $ MissionFamily $ ", " $ CurrentMissionLevel;

	return DescriptionText;
}

// (Copied from XCGS_HeadquartersAlien.AddChosenTacticalTagsToMission())
//
// Add the Chosen tactical tags to the mission if any of the following criteria
// are met:
//
//  * It's the final mission (Golden Path fortress)
//  * The Chosen has control of the region, is active, and:
//    - hasn't been encountered yet
//    - it's a Golden Path mission
//    - 20% chance on all other missions
//
// Note that if the mission type is configured to exclude Chosen, then of course
// the tactical tags aren't added for the given mission.
function MaybeAddChosenToMission(XComGameState_MissionSite MissionState)
{
	local XComGameStateHistory History;
	local XComGameState_HeadquartersAlien AlienHQ;
	local array<XComGameState_AdventChosen> AllChosen;
	local XComGameState_AdventChosen ChosenState;
	local XComGameState_MissionSiteChosenAssault ChosenAssaultMission;
	local int AppearanceChance;
	local float AppearChanceScalar;
	local name ChosenSpawningTag;

	History = `XCOMHISTORY;
	AlienHQ = XComGameState_HeadquartersAlien(History.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersAlien'));

	// LWOTC: If Chosen are disabled, don't add them at all
	if (!class'X2StrategyElement_LWObjectives'.default.ACTIVATE_CHOSEN)
	{
		return;
	}

	if(AlienHQ.bChosenActive)
	{
		AllChosen = AlienHQ.GetAllChosen(, true);
		ChosenAssaultMission = XComGameState_MissionSiteChosenAssault(MissionState);

		foreach AllChosen(ChosenState)
		{
			ChosenSpawningTag = ChosenState.GetMyTemplate().GetSpawningTag(ChosenState.Level);

			if(MissionState.TacticalGameplayTags.Find(ChosenSpawningTag) != INDEX_NONE)
			{
				continue;
			}

			if(ChosenState.ChosenControlsRegion(MissionState.Region))
			{
				if(default.ExcludeChosenFromMissionTypes.Find(MissionState.GeneratedMission.Mission.sType) != INDEX_NONE)
				{
					// Can't be on this mission no matter what
					break;
				}

				if(ChosenState.NumEncounters == 0 || MissionState.GetMissionSource().bGoldenPath)
				{
					// Guaranteed on this mission
					MissionState.TacticalGameplayTags.AddItem(ChosenSpawningTag);
					break;
				}

				// WOTC TODO: Make this configurable or use a different formula
				`LWTrace("Rolling for Chosen on mission " $ MissionState.GeneratedMission.Mission.MissionName);
				if(`SYNC_RAND(100) < 25)
				{
					`LWTrace("    Chosen added!");
					MissionState.TacticalGameplayTags.AddItem(ChosenSpawningTag);
				}

				break;
			}
		}
	}

	foreach History.IterateByClassType(class'XComGameState_AdventChosen', ChosenState)
	{
		if(ChosenState.bDefeated)
		{
			ChosenState.PurgeMissionOfTags(MissionState);
		}
	}
}

/////////////////////////////////////////////////////
///// UI Handlers

//function used to trigger a mission UI, using activity and mission info
function TriggerMissionUI(XComGameState_MissionSite MissionSite)
{
	local UIMission_LWCustomMission MissionScreen;
	local XComHQPresentationLayer HQPres;

	HQPres = `HQPRES;
	MissionScreen = HQPres.Spawn(class'UIMission_LWCustomMission', HQPres);
	MissionScreen.MissionRef = MissionSite.GetReference();
	MissionScreen.MissionUIType = GetMissionUIType(MissionSite);
	MissionScreen.bInstantInterp = false;
	MissionScreen = UIMission_LWCustomMission(HQPres.ScreenStack.Push(MissionScreen));
}

simulated function EMissionUIType GetMissionUIType(XComGameState_MissionSite MissionSite)
{
	local MissionSettings_LW MissionSettings;

    if (class'Utilities_LW'.static.GetMissionSettings(MissionSite, MissionSettings))
        return MissionSettings.MissionUIType;

	//nothing else found, default to GOps
	return eMissionUI_GuerrillaOps;
}

//function used to determine what mission icon to display on Geoscape
simulated function string GetMissionIconImage(XComGameState_MissionSite MissionSite)
{
	local MissionSettings_LW MissionSettings;

    if (class'Utilities_LW'.static.GetMissionSettings(MissionSite, MissionSettings))
	{
		`LWTrace(" >> Mission icon path = " $ MissionSettings.MissionIconPath);
        return MissionSettings.MissionIconPath;
	}

	return "img:///UILibrary_StrategyImages.X2StrategyMap.MissionIcon_GoldenPath";
}

//function for retrieving the 3D geoscape mesh used to represent a mission
simulated function string GetOverworldMeshPath(XComGameState_MissionSite MissionSite)
{
	local MissionSettings_LW MissionSettings;

    if (class'Utilities_LW'.static.GetMissionSettings(MissionSite, MissionSettings))
        return MissionSettings.OverworldMeshPath;

	//nothing else found, use a generic yellow hexagon
	return "UI_3D.Overworld.Hexagon";
}


simulated function name GetEventToTrigger(XComGameState_MissionSite MissionSite)
{
	local MissionSettings_LW MissionSettings;

    if (class'Utilities_LW'.static.GetMissionSettings(MissionSite, MissionSettings))
        return MissionSettings.EventTrigger;

	//nothing else found, default to none
	return '';

}
simulated function string GetSoundToPlay(XComGameState_MissionSite MissionSite)
{
	local MissionSettings_LW MissionSettings;

    if (class'Utilities_LW'.static.GetMissionSettings(MissionSite, MissionSettings))
        return MissionSettings.MissionSound;

	return "Geoscape_NewResistOpsMissions";
}

simulated function name GetAlertType(XComGameState_MissionSite MissionSite)
{
	local MissionSettings_LW MissionSettings;

    if (class'Utilities_LW'.static.GetMissionSettings(MissionSite, MissionSettings))
        return MissionSettings.AlertName;

	//nothing else found, default to GOps
	return 'eAlert_GOps';
}

simulated function String GetMissionImage(XComGameState_MissionSite MissionSite)
{
	local MissionSettings_LW MissionSettings;

    if (class'Utilities_LW'.static.GetMissionSettings(MissionSite, MissionSettings))
        return MissionSettings.MissionImagePath;

	// default to gops if nothing else.
	return "img:///UILibrary_StrategyImages.X2StrategyMap.Alert_Guerrilla_Ops";
}

// We need a UI class for all strategy elements (but they'll never be visible)
function class<UIStrategyMapItem> GetUIClass()
{
    return class'UIStrategyMapItem';
}

// Never show these on the map.
function bool ShouldBeVisible()
{
    return false;
}

