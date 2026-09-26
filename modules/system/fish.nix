_:

{
  programs.fish = {
    enable = true;

    shellFunctions = {
      "..".body = ''
        cd "../$argv[1]"
      '';
      "...".body = ''
        cd "../../$argv[1]"
      '';
      "....".body = ''
        cd "../../../$argv[1]"
      '';
    };

    shellAbbrs = {
      nb = "nh os boot";
      ns = "nh os switch";
      nsu = "nh os switch --update";
      mi = "micro";
      g = "git";
      ga = "git add";
      gaa = "git add .";
      gb = "git branch --all";
      gbd = "git branch -d";
      gc = "git commit";
      gca = "git commit -a";
      gcm = "git commit -m";
      gcam = "git commit -a -m";
      gco = "git checkout";
      gd = "git diff";
      gds = "git diff --staged";
      gf = "git fetch";
      gl = "git log --graph --all --pretty=format:'%Cred%h%Creset %Cgreen(%cI) -%C(yellow)%d%Creset %s %C(bold blue)<%an>%Creset' --abbrev-commit --date=rfc2822";
      gpl = "git pull";
      gp = "git push";
      gr = "git restore --staged .";
      grs = "git reset --soft HEAD^";
      grm = "git reset --mixed HEAD^";
      grh = "git reset --hard HEAD^";
      gs = "git status";
      gst = "git stash";
      gsw = "git switch -c";
    };
  };
}
