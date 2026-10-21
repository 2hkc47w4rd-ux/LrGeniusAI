-- Unit tests for the culling helpers in Util.lua.
--
-- Which tasks the prep pass sends decides whether a preset can judge the
-- moment at all, and dropping a warning is how a degraded cull looks clean.
-- Both are pure logic, so they are tested headless here.
--
-- Run from the repo root with:  busted

local Util = require("Util")

describe("Util.cullPrepTasks", function()
	it("keeps the fast path for the default preset", function()
		assert.are.same({ "cull" }, Util.cullPrepTasks("default"))
		assert.are.same({ "cull" }, Util.cullPrepTasks(nil))
		assert.are.same({ "cull" }, Util.cullPrepTasks(""))
	end)

	it("adds the embedding for every preset that judges the moment", function()
		-- Without an embedding the backend has nothing to judge emotion or
		-- action from, and ranks sports and events on sharpness alone.
		for _, preset in ipairs({ "sports", "event", "portrait", "street" }) do
			assert.is_true(Util.cullPresetJudgesMoment(preset), preset)
			assert.are.same({ "cull", "embeddings" }, Util.cullPrepTasks(preset), preset)
		end
	end)

	it("asks for the image model as well as the face model", function()
		assert.are.same({ "clip", "aesthetic", "face" }, Util.requiredModelFamilies(Util.cullPrepTasks("sports")))
		assert.are.same({ "aesthetic", "face" }, Util.requiredModelFamilies(Util.cullPrepTasks("default")))
	end)
end)

describe("Util.responseWarnings", function()
	it("prefers the list and removes duplicates", function()
		local list = Util.responseWarnings({
			warning = "a\n\nb",
			warnings = { "a", "b", "a", "" },
		})
		assert.are.same({ "a", "b" }, list)
	end)

	it("falls back to the single string of an older backend", function()
		assert.are.same({ "only" }, Util.responseWarnings({ warning = "only" }))
	end)

	it("returns an empty list when there is nothing to say", function()
		assert.are.same({}, Util.responseWarnings({ warnings = {} }))
		assert.are.same({}, Util.responseWarnings({ status = "success" }))
		assert.are.same({}, Util.responseWarnings(nil))
	end)
end)

describe("Util.formatWarningList", function()
	it("shows a handful and counts the rest", function()
		local text = Util.formatWarningList({ "1", "2", "3", "4" }, 2)
		assert.are.equal("1\n\n2\n\n... and 2 more warnings", text)
	end)

	it("shows everything when it fits", function()
		assert.are.equal("1\n\n2", Util.formatWarningList({ "1", "2" }))
	end)

	it("returns nil for no warnings", function()
		assert.is_nil(Util.formatWarningList({}))
		assert.is_nil(Util.formatWarningList(nil))
	end)
end)

describe("Util.cullRejectMarginScale", function()
	it("widens the margin for a gentle cull and narrows it for a strict one", function()
		assert.is_true(Util.cullRejectMarginScale("gentle") > 1)
		assert.are.equal(1.0, Util.cullRejectMarginScale("balanced"))
		assert.is_true(Util.cullRejectMarginScale("strict") < 1)
	end)

	it("keeps the preset's own margin for anything it does not know", function()
		assert.are.equal(1.0, Util.cullRejectMarginScale(nil))
		assert.are.equal(1.0, Util.cullRejectMarginScale("extreme"))
	end)
end)

-- A three-frame burst as `/cull/grade` returns it: a pick, an alternate and a
-- reject candidate that carried the group's strongest moment.
local function burst()
	return {
		group_id = "g1",
		photos = {
			{ photo_id = "p1", winner = true, cull_score = 0.9, reason_codes = { "sharpest_in_group" } },
			{ photo_id = "p2", cull_score = 0.8, reason_codes = { "near_duplicate_weaker" } },
			{
				photo_id = "p3",
				reject_candidate = true,
				cull_score = 0.5,
				reason_codes = { "blurred", "strong_moment_but_unusable" },
			},
		},
	}
end

describe("Util.cullSortByScore", function()
	it("orders picks best first and rejects worst first", function()
		local scores = Util.cullScoresById({ burst() })
		assert.are.same({ p1 = 0.9, p2 = 0.8, p3 = 0.5 }, scores)
		assert.are.same({ "p1", "p2", "p3" }, Util.cullSortByScore({ "p3", "p1", "p2" }, scores))
		assert.are.same({ "p3", "p2", "p1" }, Util.cullSortByScore({ "p1", "p2", "p3" }, scores, true))
	end)

	it("keeps the input order for ties and unknown ids", function()
		assert.are.same({ "a", "b", "c" }, Util.cullSortByScore({ "a", "b", "c" }, {}))
		assert.are.same({ "a", "b" }, Util.cullSortByScore({ "a", "b" }, { a = 0.5, b = 0.5 }, true))
	end)
end)

describe("Util.cullFlagPlan", function()
	local everything = {
		flagPicks = true,
		flagRejects = true,
		respectExisting = true,
		rateByDecision = true,
		labelStrongMoment = true,
	}

	it("flags, rates and labels an untouched burst", function()
		local plan, counts = Util.cullFlagPlan({ burst() }, everything, {})
		assert.are.same({ pickStatus = 1, rating = 3 }, plan.p1)
		assert.are.same({ rating = 2 }, plan.p2)
		assert.are.same({ pickStatus = -1, colorNameForLabel = "purple" }, plan.p3)
		assert.are.equal(1, counts.picks)
		assert.are.equal(1, counts.rejects)
		assert.are.equal(2, counts.ratings)
		assert.are.equal(1, counts.labels)
		assert.are.equal(0, counts.keptFlags)
	end)

	it("writes only what was asked for", function()
		local plan = Util.cullFlagPlan({ burst() }, { flagPicks = true }, {})
		assert.are.same({ pickStatus = 1 }, plan.p1)
		assert.is_nil(plan.p2)
		assert.is_nil(plan.p3)
	end)

	it("leaves the photographer's own flags, stars and labels alone", function()
		-- The user already picked p3 and rejected p1 — the opposite of the
		-- backend's view. Their decision stands; the plan says what it kept.
		local current = {
			p1 = { pickStatus = -1, rating = 1, colorNameForLabel = "red" },
			p3 = { pickStatus = 1, rating = 0, colorNameForLabel = "red" },
		}
		local plan, counts = Util.cullFlagPlan({ burst() }, everything, current)
		assert.is_nil(plan.p1)
		assert.is_nil(plan.p3)
		assert.are.same({ rating = 2 }, plan.p2)
		assert.are.equal(2, counts.keptFlags)
		assert.are.equal(1, counts.keptRatings)
		assert.are.equal(1, counts.keptLabels)
	end)

	it("overwrites and unflags alternates when told not to respect existing marks", function()
		local current = {
			p1 = { pickStatus = -1, rating = 1 },
			p2 = { pickStatus = 1 },
			p3 = { pickStatus = 1, colorNameForLabel = "red" },
		}
		local options = {
			flagPicks = true,
			flagRejects = true,
			respectExisting = false,
			rateByDecision = true,
			labelStrongMoment = true,
		}
		local plan, counts = Util.cullFlagPlan({ burst() }, options, current)
		assert.are.same({ pickStatus = 1, rating = 3 }, plan.p1)
		assert.are.same({ pickStatus = 0, rating = 2 }, plan.p2)
		assert.are.same({ pickStatus = -1, colorNameForLabel = "purple" }, plan.p3)
		assert.are.equal(1, counts.cleared)
		assert.are.equal(0, counts.keptFlags)
	end)

	it("does not write a value the photo already has", function()
		local current = { p1 = { pickStatus = 1, rating = 3 } }
		local plan, counts = Util.cullFlagPlan({ burst() }, { flagPicks = true, rateByDecision = true }, current)
		assert.is_nil(plan.p1)
		assert.are.equal(0, counts.picks)
		assert.are.equal(0, counts.keptFlags)
	end)

	it("never touches a bracket, stack or panorama", function()
		local set = burst()
		set.keep_all = true
		local plan, counts = Util.cullFlagPlan({ set }, everything, {})
		assert.is_nil(next(plan))
		assert.are.equal(0, counts.picks + counts.rejects + counts.ratings + counts.labels)
	end)

	it("treats Lightroom's 'gray' as no label", function()
		local current = { p3 = { colorNameForLabel = "gray" } }
		local plan = Util.cullFlagPlan({ burst() }, { labelStrongMoment = true }, current)
		assert.are.same({ colorNameForLabel = "purple" }, plan.p3)
	end)
end)

describe("Util.cullFlagSummaryLines", function()
	it("says what was written and what was protected", function()
		local lines = Util.cullFlagSummaryLines({ picks = 12, rejects = 30, ratings = 20, labels = 2, keptFlags = 3 })
		assert.are.equal(2, #lines)
		assert.is_truthy(lines[1]:find("12 flagged as picks", 1, true))
		assert.is_truthy(lines[1]:find("30 flagged as rejected", 1, true))
		assert.is_truthy(lines[1]:find("20 star ratings", 1, true))
		assert.is_truthy(lines[1]:find("2 purple", 1, true))
		assert.is_truthy(lines[2]:find("3 flags", 1, true))
	end)

	it("says nothing when nothing happened", function()
		assert.are.same({}, Util.cullFlagSummaryLines(nil))
		assert.are.same({}, Util.cullFlagSummaryLines({ picks = 0 }))
	end)
end)
